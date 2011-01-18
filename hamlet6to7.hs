import qualified Old.Julius as J
import qualified Old.Cassius as C
import qualified Old.Hamlet as H
import System.Environment (getArgs)

import Text.ParserCombinators.Parsec (parse)
import qualified Text.Julius as JN
import qualified Text.Cassius as CN
import qualified Text.Hamlet.Parse as HN

main = getArgs >>= mapM_ go

go fp = do
    putStrLn $ "Checking " ++ fp
    case reverse $ takeWhile (/= '.') $ reverse fp of
        "julius" -> readFile fp >>= jelper fp7
        "cassius" -> readFile fp >>= write . C.oldToNew >> check checkC
        "hamlet" -> readFile fp >>= write . H.oldToNew >> check checkH
        _ -> return ()
  where
    fp7 = fp ++ ".7"
    write = writeFile fp7
    check checker = do
        x <- checker `fmap` readFile fp7
        if x then return () else putStrLn $ "### Error parsing: " ++ fp7

jelper fp s = do
    let x = J.parse s
    let y = J.render x
    case parse JN.parseContents y y of
        Right z
            | JN.compressContents x == JN.compressContents z -> writeFile fp y
            | otherwise -> error $ unlines
                [ "Mismatch"
                , show $ JN.compressContents x
                , "versus"
                , show $ JN.compressContents z
                ]
        _ -> error "Something's wrong"

checkJ s = either (const False) (const True) $ parse JN.parseContents s s
checkC s = either (const False) (const True) $ parse CN.parseBlocks s s
checkH s =
    case HN.parseDoc HN.defaultHamletSettings s of
        HN.Error _ -> False
        HN.Ok _ -> True