{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedLists #-}

module Main where

import Control.Monad (void)
import Data.HashMap.Strict (HashMap)
import System.Exit (die)
import System.Environment (getArgs)
import Text.Megaparsec as Megaparsec
import Text.Regex.Applicative as RE
import Data.Char as Char
import Data.List as List

import Sdam.Parser (pValue, parse)
import Source.NewGen
import Source

main :: IO ()
main = do
  mParsedValue <- getArgs >>= \case
    [filepath] -> do
      content <- readFile filepath
      case parse pValue filepath content of
        Left e -> die (Megaparsec.errorBundlePretty e)
        Right a -> return (Just a)
    [] -> return Nothing
    _ -> die "Usage: hask FILE.sd"
  runSource haskPlugin mParsedValue

haskPlugin :: Plugin
haskPlugin =
  Plugin
    { _pluginSchema = haskSchema,
      _pluginRecLayouts = haskRecLayouts
    }

haskSchema :: Schema
haskSchema =
  Schema
    { schemaTypes =
        [
          "Mod"  ==> TyDefnRec ["name", "ex", "ds"],
          "Var"  ==> TyDefnStr,
          "Str"  ==> TyDefnStr,
          "Lam"  ==> TyDefnRec ["v", "b"],
          "App"  ==> TyDefnRec ["f", "a"],
          "QVar" ==> TyDefnRec ["q", "v"],
          "Sig"  ==> TyDefnRec ["v", "t"],
          "Bind" ==> TyDefnRec ["v", "b"],
          "Data" ==> TyDefnRec ["v", "alts"],
          "As" ==> TyDefnRec ["alias", "p"]
        ],
      schemaRoot = tMod
    }
  where
    tVar =
        uT "Var" $
        TyInstStr (void re)
      where
        re = re_alphavar <|> re_op
        re_fst =
          RE.psym $ \c ->
            Char.isLetter c ||
            c == '_'
        re_labelchar =
          RE.psym $ \c ->
            Char.isLetter c ||
            Char.isDigit c ||
            c == '_'
        re_opchar =
          RE.psym $ \c ->
            c `List.elem` ("!#$%&*+./<=>?@^|-~" :: [Char])
        re_alphavar =
          re_fst *> RE.many re_labelchar
        re_op =
          RE.some re_opchar
    tStr =
      uT "Str" $
      TyInstStr (void (RE.many RE.anySym))
    tQVar =
      uT "QVar" $
      TyInstRec [
        "q" ==> tVar,
        "v" ==> tVar <> tQVar
      ]
    tMod =
      uT "Mod" $
      TyInstRec [
        "name" ==> tVar <> tQVar,
        "ex"   ==> uS' tVar,
        "ds"   ==> uS' tDecl
      ]
    tLam =
      uT "Lam" $
      TyInstRec [
        "v" ==> tVar,
        "b" ==> tExpr
      ]
    tExprApp =
      uT "App" $
      TyInstRec [
        "f" ==> tExpr,
        "a" ==> tExpr
      ]
    tPatApp =
      uT "App" $
      TyInstRec [
        "f" ==> tPat,
        "a" ==> tPat
      ]
    tTypeApp =
      uT "App" $
      TyInstRec [
        "f" ==> tType,
        "a" ==> tType
      ]
    tDeclSig =
      uT "Sig" $
      TyInstRec [
        "v" ==> tVar <> uS tVar,
        "t" ==> tType
      ]
    tExprSig =
      uT "Sig" $
      TyInstRec [
        "v" ==> tExpr,
        "t" ==> tType
      ]
    tPatSig =
      uT "Sig" $
      TyInstRec [
        "v" ==> tPat,
        "t" ==> tType
      ]
    tTypeSig =
      uT "Sig" $
      TyInstRec [
        "v" ==> tType,
        "t" ==> tKind
      ]
    tBind =
      uT "Bind" $
      TyInstRec [
        "v" ==> tPat,
        "b" ==> tExpr
      ]
    tData =
      uT "Data" $
      TyInstRec [
        "v"    ==> tVar,
        "alts" ==> uS tExpr
      ]
    tAsPat =
      uT "As" $
      TyInstRec [
        "alias" ==> tVar,
        "p" ==> tPat
      ]
    tExpr =
      mconcat [
        tLam,
        tExprApp,
        tStr,
        tVar,
        tQVar,
        tExprSig
      ]
    tKind = tType
    tType =
      mconcat [
        tVar,
        tQVar,
        tTypeApp,
        tTypeSig
        -- tForall
      ]
    tPat =
      mconcat [
        tVar,
        tQVar,
        tPatApp,
        tPatSig,
        tAsPat
      ]
    tDecl =
      mconcat [
        tDeclSig,
        tBind,
        tData
      ]

haskRecLayouts :: HashMap TyName ALayoutFn
haskRecLayouts = recLayouts
  where
    recLayouts =
      [
        "Lam"  ==> recLayoutLam,
        "App"  ==> recLayoutApp,
        "Mod"  ==> recLayoutMod,
        "QVar" ==> recLayoutQVar,
        "Sig"  ==> recLayoutSig,
        "Bind" ==> recLayoutBind,
        "Data" ==> recLayoutData,
        "As"   ==> recLayoutAs
      ]
    recLayoutQVar =
      field "q" noPrec "q" <> "." <> field "v" precAllowAll "v"
    recLayoutApp =
      field "f" (precAllow ["App"]) "function" <>
      field "a" (precAllow ["Var", "QVar"]) "argument"
    recLayoutLam =
      jumptag "λ" <> field "v" precAllowAll "variable"
      `vsep` field "b" precAllowAll "body"
    recLayoutMod =
      jumptag "module" <> field "name" (precAllow ["Var", "QVar"]) "name" <> field "ex" precAllowAll "export"
      `vsep` field "ds" precAllowAll "declarations"
    recLayoutSig =
      field "v" noPrec "variable" <> jumptag "::" <> field "t" precAllowAll "type"
    recLayoutBind =
      field "v" noPrec "variable" <> jumptag "=" <> field "b" precAllowAll "body"
    recLayoutData =
      jumptag "data" <> field "v" noPrec "name" <> "=" <> field "alts" precAllowAll "alternatives"
    recLayoutAs =
      field "alias" noPrec "alias" <> jumptag "@" <> field "p" noPrec "pattern"
