{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE RecordWildCards #-}
{-# OPTIONS_GHC -fno-warn-missing-fields #-}
{-# OPTIONS_GHC -fno-warn-incomplete-patterns #-}
-- | For lack of a better name... a parameterized version of Julius.
module Text.Shakespeare
    ( ShakespeareSettings (..)
    , PreConvert (..)
    , WrapInsertion (..)
    , PreConversion (..)
    , defaultShakespeareSettings
    , shakespeare
    , shakespeareFile
    , shakespeareFileReload
    -- * low-level
    , shakespeareFromString
    , shakespeareUsedIdentifiers
    , RenderUrl
    , VarType
    , Deref
    , Parser

#ifdef TEST_EXPORT
    , preFilter
#endif
    ) where

import Data.List (intersperse)
import Data.Char (isAlphaNum, isSpace)
import Text.ParserCombinators.Parsec hiding (Line, parse, Parser)
import Text.Parsec.Prim (modifyState, Parsec)
import Language.Haskell.TH.Quote (QuasiQuoter (..))
import Language.Haskell.TH (appE)
import Language.Haskell.TH.Syntax
#if !MIN_VERSION_template_haskell(2,8,0)
import Language.Haskell.TH.Syntax.Internals
#endif
import Data.Text.Lazy.Builder (Builder, fromText)
import Data.Monoid
import System.IO.Unsafe (unsafePerformIO)
import qualified Data.Text as TS
import qualified Data.Text.Lazy as TL
import Text.Shakespeare.Base

-- for pre conversion
import System.Process (readProcess)

-- | A parser with a user state of [String]
type Parser = Parsec String [String]
-- | run a parser with a user state of [String]
parse ::  GenParser tok [a1] a -> SourceName -> [tok] -> Either ParseError a
parse p = runParser p []

-- move to Shakespeare.Base?
readFileQ :: FilePath -> Q String
readFileQ fp = qRunIO $ readFileUtf8 fp

-- move to Shakespeare.Base?
readFileUtf8 :: FilePath -> IO String
readFileUtf8 fp = fmap TL.unpack $ readUtf8File fp

-- | Coffeescript, TypeScript, and other languages compiles down to Javascript.
-- Previously we waited until the very end, at the rendering stage to perform this compilation.
-- Lets call is a post-conversion
-- This had the advantage that all Haskell values were inserted first:
-- for example a value could be inserted that Coffeescript would compile into Javascript.
-- While that is perhaps a safer approach, the advantage is not used in practice:
-- it was that way mainly for ease of implementation.
-- The down-side is the template must be compiled down to Javascript during every request.
-- If instead we do a pre-conversion to compile down to Javascript,
-- we only need to perform the compilation once.
--
-- The problem then is the insertion of Haskell values: we need a hole for
-- them. This can be done with variables known to the language.
-- During the pre-conversion we first modify all Haskell insertions
-- So #{a} is change to shakespeare_var_a
-- Then we can place the Haskell values in a function wrapper that exposes
-- those variables: (function(shakespeare_var_a){ ... shakespeare_var_a ...})
-- TypeScript can compile that, and then we tack an application of the
-- Haskell values onto the result: (#{a})
--
-- preEscapeIgnoreBalanced is used to not insert backtacks for variable already inside strings or backticks.
-- coffeescript will happily ignore the interpolations, and backticks would not be treated as escaping in that context.
-- preEscapeIgnoreLine was added to ignore comments (which in Coffeescript begin with a '#')

data PreConvert = PreConvert
    { preConvert :: PreConversion
    , preEscapeIgnoreBalanced :: [Char]
    , preEscapeIgnoreLine :: [Char]
    , wrapInsertion :: Maybe WrapInsertion
    }

data WrapInsertion = WrapInsertion {
      wrapInsertionIndent     :: Maybe String
    , wrapInsertionStartBegin :: String
    , wrapInsertionSeparator  :: String
    , wrapInsertionStartClose :: String
    , wrapInsertionEnd :: String
    , wrapInsertionApplyBegin :: String
    , wrapInsertionApplyClose :: String
    }

data PreConversion = ReadProcess String [String]
                   | Id
  


data ShakespeareSettings = ShakespeareSettings
    { varChar :: Char
    , urlChar :: Char
    , intChar :: Char
    , toBuilder :: Exp
    , wrap :: Exp
    , unwrap :: Exp
    , justVarInterpolation :: Bool
    , preConversion :: Maybe PreConvert
    , modifyFinalValue :: Maybe Exp
    -- ^ A transformation applied to the final expression. Most often, this
    -- would be used to force the type of the expression to help make more
    -- meaningful error messages.
    }

defaultShakespeareSettings :: ShakespeareSettings
defaultShakespeareSettings = ShakespeareSettings {
    varChar = '#'
  , urlChar = '@'
  , intChar = '^'
  , justVarInterpolation = False
  , preConversion = Nothing
  , modifyFinalValue = Nothing
}

instance Lift PreConvert where
    lift (PreConvert convert ignore comment wrapInsertion) =
        [|PreConvert $(lift convert) $(lift ignore) $(lift comment) $(lift wrapInsertion)|]

instance Lift WrapInsertion where
    lift (WrapInsertion indent sb sep sc e ab ac) =
        [|WrapInsertion $(lift indent) $(lift sb) $(lift sep) $(lift sc) $(lift e) $(lift ab) $(lift ac)|]

instance Lift PreConversion where
    lift (ReadProcess command args) =
        [|ReadProcess $(lift command) $(lift args)|]
    lift Id = [|Id|]

instance Lift ShakespeareSettings where
    lift (ShakespeareSettings x1 x2 x3 x4 x5 x6 x7 x8 x9) =
        [|ShakespeareSettings
            $(lift x1) $(lift x2) $(lift x3)
            $(liftExp x4) $(liftExp x5) $(liftExp x6) $(lift x7) $(lift x8) $(liftMExp x9)|]
      where
        liftExp (VarE n) = [|VarE $(liftName n)|]
        liftExp (ConE n) = [|ConE $(liftName n)|]
        liftExp _ = error "liftExp only supports VarE and ConE"
        liftMExp Nothing = [|Nothing|]
        liftMExp (Just e) = [|Just|] `appE` liftExp e
        liftName (Name (OccName a) b) = [|Name (OccName $(lift a)) $(liftFlavour b)|]
        liftFlavour NameS = [|NameS|]
        liftFlavour (NameQ (ModName a)) = [|NameQ (ModName $(lift a))|]
        liftFlavour (NameU _) = error "liftFlavour NameU" -- [|NameU $(lift $ fromIntegral a)|]
        liftFlavour (NameL _) = error "liftFlavour NameL" -- [|NameU $(lift $ fromIntegral a)|]
        liftFlavour (NameG ns (PkgName p) (ModName m)) = [|NameG $(liftNS ns) (PkgName $(lift p)) (ModName $(lift m))|]
        liftNS VarName = [|VarName|]
        liftNS DataName = [|DataName|]

type QueryParameters = [(TS.Text, TS.Text)]
type RenderUrl url = (url -> QueryParameters -> TS.Text)
type Shakespeare url = RenderUrl url -> Builder

data Content = ContentRaw String
             | ContentVar Deref
             | ContentUrl Deref
             | ContentUrlParam Deref
             | ContentMix Deref
    deriving (Show, Eq)
type Contents = [Content]

eShowErrors :: Either ParseError c -> c
eShowErrors = either (error . show) id

contentFromString :: ShakespeareSettings -> String -> [Content]
contentFromString _ "" = []
contentFromString rs s =
    compressContents $ eShowErrors $ parse (parseContents rs) s s
  where
    compressContents :: Contents -> Contents
    compressContents [] = []
    compressContents (ContentRaw x:ContentRaw y:z) =
        compressContents $ ContentRaw (x ++ y) : z
    compressContents (x:y) = x : compressContents y
    
parseContents :: ShakespeareSettings -> Parser Contents
parseContents = many1 . parseContent
  where
    parseContent :: ShakespeareSettings -> Parser Content
    parseContent ShakespeareSettings {..} =
        parseVar' <|> parseUrl' <|> parseInt' <|> parseChar'
      where
        parseVar' = either ContentRaw ContentVar `fmap` parseVar varChar
        parseUrl' = either ContentRaw contentUrl `fmap` parseUrl urlChar '?'
          where
            contentUrl (d, False) = ContentUrl d
            contentUrl (d, True) = ContentUrlParam d

        parseInt' = either ContentRaw ContentMix `fmap` parseInt intChar
        parseChar' = ContentRaw `fmap` many1 (noneOf [varChar, urlChar, intChar])


preFilter :: ShakespeareSettings -> String -> IO String
preFilter ShakespeareSettings {..} template =
    case preConversion of
      Nothing -> return template
      Just pre@(PreConvert convert _ _ mwi) ->
        if all isSpace template then return template else
          let (groups, rvars) = eShowErrors $ parse
                                  (parseConvertWrapInsertion mwi pre)
                                  template
                                  (indentedTemplate mwi)
              vars = reverse rvars
              parsed = mconcat groups
          in  applyVars mwi vars `fmap` (case convert of
                  Id -> return  
                  ReadProcess command args -> readProcess command args
                ) (addVars mwi vars parsed)
  where
    indentedTemplate Nothing = template
    indentedTemplate (Just wi) = addIndent $ wrapInsertionIndent wi
      where
        addIndent Nothing = template
        addIndent (Just indent) = mapLines (\line -> indent <> line) template
        mapLines f = unlines . map f . lines

    shakespeare_prefix = "shakespeare_var_"
    shakespeare_var_conversion ('@':'?':'{':str) = shakespeare_var_conversion ('@':'{':str)
    shakespeare_var_conversion (_:'{':str) = shakespeare_prefix <> filter isAlphaNum (init str)
    shakespeare_var_conversion err = error $ "did not expect: " <> err

    applyVars Nothing _ str = str
    applyVars _ [] str = str
    applyVars (Just WrapInsertion {..}) vars str =
      reverse (dropWhile (\c -> c == ';' || isSpace c) (reverse str))
      <> wrapInsertionApplyBegin
      <> (mconcat $ intersperse wrapInsertionSeparator vars)
      <> wrapInsertionApplyClose

    addVars Nothing _ str = str
    addVars _ [] str = str
    addVars (Just WrapInsertion {..}) vars str =
         wrapInsertionStartBegin
      <> (mconcat $ intersperse wrapInsertionSeparator $ map shakespeare_var_conversion vars)
      <> wrapInsertionStartClose
      <> str
      <> wrapInsertionEnd

    parseConvertWrapInsertion Nothing = parseConvert id
    parseConvertWrapInsertion (Just _) = parseConvert shakespeare_var_conversion

    parseConvert varConvert PreConvert {..} = do
        str <- many1 $ choice $
          map (try . escapedParse) preEscapeIgnoreBalanced ++ [mainParser]
        st <- getState
        return (str, st)

      where
        escapedParse ignoreC = do
            _<- char ignoreC
            inside <- many $ noneOf [ignoreC]
            _<- char ignoreC
            return $ ignoreC:inside ++ [ignoreC]

        mainParser =
            parseVar' <|>
            parseUrl' <|>
            parseInt' <|>
            parseCommentLine preEscapeIgnoreLine <|>
            parseChar' preEscapeIgnoreLine preEscapeIgnoreBalanced

        recordRight (Left str)  = return str
        recordRight (Right str) = modifyState (\vars -> str:vars) >> (return $ varConvert str)

        newLine = "\r\n"
        parseCommentLine cs = do
          begin <- oneOf cs
          comment <- many $ noneOf newLine
          return $ begin : comment

        parseVar' :: (Parsec String [String]) String
        parseVar' = recordRight =<< parseVarString varChar
        parseUrl' = recordRight =<< parseUrlString urlChar '?'
        parseInt' = recordRight =<< parseIntString intChar
        parseChar' comments ignores =
            many1 (noneOf ([varChar, urlChar, intChar] ++ comments ++ ignores))

pack' :: String -> TS.Text
pack' = TS.pack
#if !MIN_VERSION_text(0, 11, 2)
{-# NOINLINE pack' #-}
#endif

contentsToShakespeare :: ShakespeareSettings -> [Content] -> Q Exp
contentsToShakespeare rs a = do
    r <- newName "_render"
    c <- mapM (contentToBuilder r) a
    compiledTemplate <- case c of
        -- Make sure we convert this mempty using toBuilder to pin down the
        -- type appropriately
        []  -> fmap (AppE $ wrap rs) [|mempty|]
        [x] -> return x
        _   -> do
              mc <- [|mconcat|]
              return $ mc `AppE` ListE c
    fmap (maybe id AppE $ modifyFinalValue rs) $
        if justVarInterpolation rs
            then return compiledTemplate
            else return $ LamE [VarP r] compiledTemplate
      where
        contentToBuilder :: Name -> Content -> Q Exp
        contentToBuilder _ (ContentRaw s') = do
            ts <- [|fromText . pack'|]
            return $ wrap rs `AppE` (ts `AppE` LitE (StringL s'))
        contentToBuilder _ (ContentVar d) =
            return $ wrap rs `AppE` (toBuilder rs `AppE` derefToExp [] d)
        contentToBuilder r (ContentUrl d) = do
            ts <- [|fromText|]
            return $ wrap rs `AppE` (ts `AppE` (VarE r `AppE` derefToExp [] d `AppE` ListE []))
        contentToBuilder r (ContentUrlParam d) = do
            ts <- [|fromText|]
            up <- [|\r' (u, p) -> r' u p|]
            return $ wrap rs `AppE` (ts `AppE` (up `AppE` VarE r `AppE` derefToExp [] d))
        contentToBuilder r (ContentMix d) =
            return $ derefToExp [] d `AppE` VarE r

shakespeare :: ShakespeareSettings -> QuasiQuoter
shakespeare r = QuasiQuoter { quoteExp = shakespeareFromString r }

shakespeareFromString :: ShakespeareSettings -> String -> Q Exp
shakespeareFromString r str = do
    s <- qRunIO $ preFilter r str
    contentsToShakespeare r $ contentFromString r s

shakespeareFile :: ShakespeareSettings -> FilePath -> Q Exp
shakespeareFile r fp = do
#ifdef GHC_7_4
    qAddDependentFile fp
#endif
    readFileQ fp >>= shakespeareFromString r

data VarType = VTPlain | VTUrl | VTUrlParam | VTMixin

getVars :: Content -> [(Deref, VarType)]
getVars ContentRaw{} = []
getVars (ContentVar d) = [(d, VTPlain)]
getVars (ContentUrl d) = [(d, VTUrl)]
getVars (ContentUrlParam d) = [(d, VTUrlParam)]
getVars (ContentMix d) = [(d, VTMixin)]

data VarExp url = EPlain Builder
                | EUrl url
                | EUrlParam (url, [(TS.Text, TS.Text)])
                | EMixin (Shakespeare url)

-- | Determine which identifiers are used by the given template, useful for
-- creating systems like yesod devel.
shakespeareUsedIdentifiers :: ShakespeareSettings -> String -> [(Deref, VarType)]
shakespeareUsedIdentifiers settings = concatMap getVars . contentFromString settings

shakespeareFileReload :: ShakespeareSettings -> FilePath -> Q Exp
shakespeareFileReload rs fp = do
    str <- readFileQ fp
    s <- qRunIO $ preFilter rs str
    let b = shakespeareUsedIdentifiers rs s
    c <- mapM vtToExp b
    rt <- [|shakespeareRuntime|]
    wrap' <- [|\x -> $(return $ wrap rs) . x|]
    r' <- lift rs
    return $ wrap' `AppE` (rt `AppE` r' `AppE` (LitE $ StringL fp) `AppE` ListE c)
  where
    vtToExp :: (Deref, VarType) -> Q Exp
    vtToExp (d, vt) = do
        d' <- lift d
        c' <- c vt
        return $ TupE [d', c' `AppE` derefToExp [] d]
      where
        c :: VarType -> Q Exp
        c VTPlain = [|EPlain . $(return $ toBuilder rs)|]
        c VTUrl = [|EUrl|]
        c VTUrlParam = [|EUrlParam|]
        c VTMixin = [|\x -> EMixin $ \r -> $(return $ unwrap rs) $ x r|]


shakespeareRuntime :: ShakespeareSettings -> FilePath -> [(Deref, VarExp url)] -> Shakespeare url
shakespeareRuntime rs fp cd render' = unsafePerformIO $ do
    str <- readFileUtf8 fp
    s <- preFilter rs str
    return $ mconcat $ map go $ contentFromString rs s
  where
    go :: Content -> Builder
    go (ContentRaw s) = fromText $ TS.pack s
    go (ContentVar d) =
        case lookup d cd of
            Just (EPlain s) -> s
            _ -> error $ show d ++ ": expected EPlain"
    go (ContentUrl d) =
        case lookup d cd of
            Just (EUrl u) -> fromText $ render' u []
            _ -> error $ show d ++ ": expected EUrl"
    go (ContentUrlParam d) =
        case lookup d cd of
            Just (EUrlParam (u, p)) ->
                fromText $ render' u p
            _ -> error $ show d ++ ": expected EUrlParam"
    go (ContentMix d) =
        case lookup d cd of
            Just (EMixin m) -> m render'
            _ -> error $ show d ++ ": expected EMixin"
