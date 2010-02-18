-- | A variant of /Node/ in which Element nodes have an annotation of any type,
-- and some concrete functions that annotate with the XML parse location.
-- It is assumed you will usually want /Tree/ or /Annotated/, not both, so many
-- of the names conflict.
--
-- Support for qualified and namespaced trees annotated with location information
-- is not complete.
module Text.XML.Expat.Annotated (
  -- * Tree structure
  Node(..),
  Attributes,  -- re-export from Tree
  UNode,
  UAttributes,
  LNode,
  ULNode,
  textContent,
  isElement,
  isNamed,
  isText,
  getAttribute,
  getChildren,
  modifyChildren,
  unannotate,

  -- * Qualified nodes
  QName(..),
  QNode,
  QAttributes,
  QLNode,

  -- * Namespaced nodes
  NName (..),
  NNode,
  NAttributes,
  NLNode,
  mkNName,
  mkAnNName,
  xmlnsUri,
  xmlns,

  -- * Parse to tree
  Tree.ParserOptions(..),
  Tree.defaultParserOptions,
  Encoding(..),
  parse,
  parse',
  XMLParseError(..),
  XMLParseLocation(..),

  -- * Variant that throws exceptions
  parseThrowing,
  XMLParseException(..),

  -- * SAX-style parse
  SAXEvent(..),
  saxToTree,

  -- * Abstraction of string types
  GenericXMLString(..),

  -- * Deprecated
  parseSAX,
  parseSAXThrowing,
  parseSAXLocations,
  parseSAXLocationsThrowing,
  parseTree,
  parseTree',
  parseTreeThrowing
) where

import Text.XML.Expat.Tree ( Attributes, UAttributes )
import qualified Text.XML.Expat.Tree as Tree
import Text.XML.Expat.SAX ( Encoding(..)
                          , GenericXMLString(..)
                          , ParserOptions(..)
                          , SAXEvent(..)
                          , XMLParseError(..)
                          , XMLParseException(..)
                          , XMLParseLocation(..)
                          , parseSAX
                          , parseSAXThrowing
                          , parseSAXLocations
                          , parseSAXLocationsThrowing )

import qualified Text.XML.Expat.SAX as SAX
import Text.XML.Expat.Qualified hiding (QNode, QNodes)
import Text.XML.Expat.Namespaced hiding (NNode, NNodes)

import Control.Monad (mplus)
import Control.Parallel.Strategies
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import Data.Monoid


-- | Annotated variant of the tree representation of the XML document.
data Node tag text a =
    Element {
        eName     :: !tag,
        eAttrs    :: ![(tag,text)],
        eChildren :: [Node tag text a],
        eAnn      :: a
    } |
    Text !text
    deriving (Eq, Show)

instance (NFData tag, NFData text, NFData a) => NFData (Node tag text a) where
    rnf (Element nam att chi ann) = rnf (nam, att, chi, ann)
    rnf (Text txt) = rnf txt

unannotate :: Node tag text a -> Tree.Node tag text
unannotate (Element na at ch _) = (Tree.Element na at (map unannotate ch))
unannotate (Text t) = Tree.Text t

-- | Extract all text content from inside a tag into a single string, including
-- any text contained in children.
textContent :: Monoid text => Node tag text a -> text
textContent (Element _ _ children _) = mconcat $ map textContent children
textContent (Text txt) = txt

-- | Is the given node an element?
isElement :: Node tag text a -> Bool
isElement (Element _ _ _ _) = True
isElement _                 = False

-- | Is the given node text?
isText :: Node tag text a -> Bool
isText (Text _) = True
isText _        = False

-- | Is the given node a tag with the given name?
isNamed :: (Eq tag) => tag -> Node tag text a -> Bool
isNamed _  (Text _) = False
isNamed nm (Element nm' _ _ _) = nm == nm'

-- | Get the value of the attribute having the specified name.
getAttribute :: GenericXMLString tag => Node tag text a -> tag -> Maybe text
getAttribute n t = lookup t $ eAttrs n

-- | Get children of a node if it's an element, return empty list otherwise.
getChildren :: Node tag text a -> [Node tag text a]
getChildren (Text _)           = []
getChildren (Element _ _ ch _) = ch

-- | Modify a node's children using the specified function.
modifyChildren :: ([Node tag text a] -> [Node tag text a])
               -> Node tag text a
               -> Node tag text a
modifyChildren _ node@(Text _) = node
modifyChildren f (Element n a c ann) = Element n a (f c) ann

-- | Type shortcut for a single annotated node with unqualified tag names where
-- tag and text are the same string type
type UNode text a = Node text text a

-- | Type shortcut for a single annotated node, annotated with parse location
type LNode tag text = Node tag text XMLParseLocation

-- | Type shortcut for a single node with unqualified tag names where
-- tag and text are the same string type, annotated with parse location
type ULNode text = LNode text text 

-- | Type shortcut for a single annotated node where qualified names are used for tags
type QNode text a = Node (QName text) text a

-- | Type shortcut for a single node where qualified names are used for tags, annotated with parse location
type QLNode text = LNode (QName text) text

-- | Type shortcut for a single annotated node where namespaced names are used for tags
type NNode text a = Node (NName text) text a

-- | Type shortcut for a single node where namespaced names are used for tags, annotated with parse location
type NLNode text = LNode (NName text) text

instance Functor (Node tag text) where
    f `fmap` Element na at ch an = Element na at (map (f `fmap`) ch) (f an)
    _ `fmap` Text t = Text t

-- | A lower level function that lazily converts a SAX stream into a tree structure.
-- Variant that takes annotations for start tags.
saxToTree :: GenericXMLString tag =>
             [(SAXEvent tag text, a)]
          -> (Node tag text a, Maybe XMLParseError)
saxToTree events =
    let (nodes, mError, _) = ptl events
    in  (safeHead nodes, mError)
  where
    safeHead (a:_) = a
    safeHead [] = Element (gxFromString "") [] [] (error "saxToTree null annotation")
    ptl ((StartElement name attrs, ann):rema) =
        let (children, err1, rema') = ptl rema
            elt = Element name attrs children ann
            (out, err2, rema'') = ptl rema'
        in  (elt:out, err1 `mplus` err2, rema'')
    ptl ((EndElement _, _):rema) = ([], Nothing, rema)
    ptl ((CharacterData txt, _):rema) =
        let (out, err, rema') = ptl rema
        in  (Text txt:out, err, rema')
    ptl ((FailDocument err, _):_) = ([], Just err, [])
    ptl [] = ([], Nothing, [])

-- | Lazily parse XML to tree. Note that forcing the XMLParseError return value
-- will force the entire parse.  Therefore, to ensure lazy operation, don't
-- check the error status until you have processed the tree.
parse :: (GenericXMLString tag, GenericXMLString text) =>
         ParserOptions tag text   -- ^ Optional encoding override
      -> L.ByteString             -- ^ Input text (a lazy ByteString)
      -> (LNode tag text, Maybe XMLParseError)
parse opts bs = saxToTree $ SAX.parseLocations opts bs

-- | DEPRECATED: Use 'parse' instead.
--
-- Lazily parse XML to tree. Note that forcing the XMLParseError return value
-- will force the entire parse.  Therefore, to ensure lazy operation, don't
-- check the error status until you have processed the tree.
parseTree :: (GenericXMLString tag, GenericXMLString text) =>
             Maybe Encoding      -- ^ Optional encoding override
          -> L.ByteString        -- ^ Input text (a lazy ByteString)
          -> (LNode tag text, Maybe XMLParseError)
{-# DEPRECATED parseTree "use Text.XML.Annotated.parse instead" #-}
parseTree mEnc = parse (ParserOptions mEnc Nothing)

-- | Lazily parse XML to tree. In the event of an error, throw 'XMLParseException'.
--
-- @parseThrowing@ can throw an exception from pure code, which is generally a bad
-- way to handle errors, because Haskell\'s lazy evaluation means it\'s hard to
-- predict where it will be thrown from.  However, it may be acceptable in
-- situations where it's not expected during normal operation, depending on the
-- design of your program.
parseThrowing :: (GenericXMLString tag, GenericXMLString text) =>
                 ParserOptions tag text   -- ^ Optional encoding override
              -> L.ByteString             -- ^ Input text (a lazy ByteString)
              -> LNode tag text
parseThrowing opts bs = fst $ saxToTree $ SAX.parseLocationsThrowing opts bs

-- | DEPRECATED: use 'parseThrowing' instead
--
-- Lazily parse XML to tree. In the event of an error, throw 'XMLParseException'.
parseTreeThrowing :: (GenericXMLString tag, GenericXMLString text) =>
             Maybe Encoding      -- ^ Optional encoding override
          -> L.ByteString        -- ^ Input text (a lazy ByteString)
          -> LNode tag text
{-# DEPRECATED parseTreeThrowing "use Text.XML.Annotated.parseThrowing instead" #-}
parseTreeThrowing mEnc = parseThrowing (ParserOptions mEnc Nothing)

-- | Strictly parse XML to tree. Returns error message or valid parsed tree.
parse' :: (GenericXMLString tag, GenericXMLString text) =>
          ParserOptions tag text  -- ^ Optional encoding override
       -> B.ByteString            -- ^ Input text (a strict ByteString)
       -> Either XMLParseError (LNode tag text)
parse' opts bs = case parse opts (L.fromChunks [bs]) of
    (_, Just err)   -> Left err
    (root, Nothing) -> Right root 

-- | DEPRECATED: use 'parse' instead.
--
-- Strictly parse XML to tree. Returns error message or valid parsed tree.
parseTree' :: (GenericXMLString tag, GenericXMLString text) =>
              Maybe Encoding      -- ^ Optional encoding override
           -> B.ByteString        -- ^ Input text (a strict ByteString)
           -> Either XMLParseError (LNode tag text)
{-# DEPRECATED parseTree' "use Text.XML.Expat.parse' instead" #-}
parseTree' mEnc = parse' (ParserOptions mEnc Nothing)

