{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE UnboxedTuples #-}

module Parse.Space (
  Parser,
  --
  chomp,
  chompIndentedMoreThan,
  chompAndCheckIndent,
  --
  checkIndent,
  checkAligned,
  checkFreshLine,
  --
  docComment,
)
where

import AST.Source qualified as Src
import Data.Utf8 qualified as Utf8
import Data.Word (Word32, Word8)
import Foreign.ForeignPtr.Unsafe (unsafeForeignPtrToPtr)
import Foreign.Ptr (Ptr, minusPtr, plusPtr)
import Parse.Primitives (Col, Row)
import Parse.Primitives qualified as P
import Reporting.Annotation qualified as A
import Reporting.Error.Syntax qualified as E

-- SPACE PARSING

type Parser x a =
  P.Parser x (a, A.Position)

-- CHOMP

chomp :: (E.Space -> Row -> Col -> x) -> P.Parser x [Src.Comment]
chomp =
  chompIndentedMoreThan 0

chompIndentedMoreThan :: Col -> (E.Space -> Row -> Col -> x) -> P.Parser x [Src.Comment]
chompIndentedMoreThan requiredIndent toError =
  P.Parser $ \(P.State src pos end indent row col) cok _ cerr _ ->
    let (# status, newPos, newRow, newCol #) = eatSpacesIndentedMoreThan requiredIndent pos end row col []
     in case status of
          Good comments ->
            let !newState = P.State src newPos end indent newRow newCol
             in cok comments newState
          HasTab -> cerr newRow newCol (toError E.HasTab)
          EndlessMultiComment -> cerr newRow newCol (toError E.EndlessMultiComment)

-- CHECKS -- to be called right after a `chomp`

checkIndent :: A.Position -> (Row -> Col -> x) -> P.Parser x ()
checkIndent (A.Position endRow endCol) toError =
  P.Parser $ \state@(P.State _ _ _ indent _ col) _ eok _ eerr ->
    if col > indent && col > 1
      then eok () state
      else eerr endRow endCol toError

checkAligned :: (Word32 -> Row -> Col -> x) -> P.Parser x ()
checkAligned toError =
  P.Parser $ \state@(P.State _ _ _ indent row col) _ eok _ eerr ->
    if col == indent
      then eok () state
      else eerr row col (toError indent)

checkFreshLine :: (Row -> Col -> x) -> P.Parser x ()
checkFreshLine toError =
  P.Parser $ \state@(P.State _ _ _ _ row col) _ eok _ eerr ->
    if col == 1
      then eok () state
      else eerr row col toError

-- CHOMP AND CHECK

chompAndCheckIndent :: (E.Space -> Row -> Col -> x) -> (Row -> Col -> x) -> P.Parser x [Src.Comment]
chompAndCheckIndent toSpaceError toIndentError =
  P.Parser $ \(P.State src pos end indent row col) cok _ cerr _ ->
    let (# status, newPos, newRow, newCol #) = eatSpacesIndentedMoreThan 0 pos end row col []
     in case status of
          Good comments ->
            if newCol > indent && newCol > 1
              then
                let !newState = P.State src newPos end indent newRow newCol
                 in cok comments newState
              else cerr row col toIndentError
          HasTab -> cerr newRow newCol (toSpaceError E.HasTab)
          EndlessMultiComment -> cerr newRow newCol (toSpaceError E.EndlessMultiComment)

-- EAT SPACES

data Status
  = Good [Src.Comment]
  | HasTab
  | EndlessMultiComment

eatSpacesIndentedMoreThan :: Col -> Ptr Word8 -> Ptr Word8 -> Row -> Col -> [Src.Comment] -> (# Status, Ptr Word8, Row, Col #)
eatSpacesIndentedMoreThan indent pos end row col comments =
  if pos >= end
    then (# Good (reverse comments), pos, row, col #)
    else case P.unsafeIndex pos of
      0x20 {-   -} ->
        eatSpacesIndentedMoreThan indent (plusPtr pos 1) end row (col + 1) comments
      0x0A {- \n -} ->
        eatSpacesIndentedMoreThan indent (plusPtr pos 1) end (row + 1) 1 comments
      0x7B {- { -} ->
        if col > indent
          then eatMultiComment indent pos end row col comments
          else (# Good (reverse comments), pos, row, col #)
      0x2D {- - -} ->
        let !pos1 = plusPtr pos 1
         in if pos1 < end && col > indent && P.unsafeIndex pos1 == 0x2D {- - -}
              then
                let !start = plusPtr pos 2
                 in eatLineComment indent start start end row col (col + 2) comments
              else (# Good (reverse comments), pos, row, col #)
      0x0D {- \r -} ->
        eatSpacesIndentedMoreThan indent (plusPtr pos 1) end row col comments
      0x09 {- \t -} ->
        (# HasTab, pos, row, col #)
      _ ->
        (# Good (reverse comments), pos, row, col #)

-- LINE COMMENTS

eatLineComment :: Col -> Ptr Word8 -> Ptr Word8 -> Ptr Word8 -> Row -> Col -> Col -> [Src.Comment] -> (# Status, Ptr Word8, Row, Col #)
eatLineComment indent start pos end row startCol col comments =
  if pos >= end
    then
      let !commentText = Utf8.fromPtr start end
          !comment_ = Src.LineComment commentText
          !comment = A.At (A.Region (A.Position row startCol) (A.Position row col)) comment_
          !finalComments = comment : comments
       in (# Good (reverse finalComments), pos, row, col #)
    else
      let !word = P.unsafeIndex pos
       in if word == 0x0A {- \n -}
            then
              let !commentText = Utf8.fromPtr start pos
                  !comment_ = Src.LineComment commentText
                  !comment = A.At (A.Region (A.Position row startCol) (A.Position row col)) comment_
                  !newComments = comment : comments
               in eatSpacesIndentedMoreThan indent (plusPtr pos 1) end (row + 1) 1 newComments
            else
              let !newPos = plusPtr pos (P.getCharWidth word)
               in eatLineComment indent start newPos end row startCol (col + 1) comments

-- MULTI COMMENTS

eatMultiComment :: Col -> Ptr Word8 -> Ptr Word8 -> Row -> Col -> [Src.Comment] -> (# Status, Ptr Word8, Row, Col #)
eatMultiComment indent pos end row col comments =
  let !pos1 = plusPtr pos 1
      !pos2 = plusPtr pos 2
   in if pos2 >= end
        then (# Good (reverse comments), pos, row, col #)
        else
          if P.unsafeIndex pos1 == 0x2D {- - -}
            then
              if P.unsafeIndex pos2 == 0x7C
                then (# Good (reverse comments), pos, row, col #)
                else
                  let (# status, newPos, newRow, newCol #) =
                        eatMultiCommentHelp pos2 pos2 end row (col + 2) 1
                   in case status of
                        MultiGood commentText ->
                          let !comment_ = Src.BlockComment commentText
                              !comment = A.At (A.Region (A.Position row col) (A.Position newRow newCol)) comment_
                              !newComments = comment : comments
                           in eatSpacesIndentedMoreThan indent newPos end newRow newCol newComments
                        MultiTab -> (# HasTab, newPos, newRow, newCol #)
                        MultiEndless -> (# EndlessMultiComment, pos, row, col #)
            else (# Good (reverse comments), pos, row, col #)

data MultiStatus
  = MultiGood !(Utf8.Utf8 Src.GREN_COMMENT)
  | MultiTab
  | MultiEndless

eatMultiCommentHelp :: Ptr Word8 -> Ptr Word8 -> Ptr Word8 -> Row -> Col -> Word32 -> (# MultiStatus, Ptr Word8, Row, Col #)
eatMultiCommentHelp start pos end row col openComments =
  if pos >= end
    then (# MultiEndless, pos, row, col #)
    else
      let !word = P.unsafeIndex pos
       in if word == 0x0A {- \n -}
            then eatMultiCommentHelp start (plusPtr pos 1) end (row + 1) 1 openComments
            else
              if word == 0x09 {- \t -}
                then (# MultiTab, pos, row, col #)
                else
                  if word == 0x2D {- - -} && P.isWord (plusPtr pos 1) end 0x7D {- } -}
                    then
                      if openComments == 1
                        then
                          let !comment = Utf8.fromPtr start pos
                           in (# MultiGood comment, plusPtr pos 2, row, col + 2 #)
                        else eatMultiCommentHelp start (plusPtr pos 2) end row (col + 2) (openComments - 1)
                    else
                      if word == 0x7B {- { -} && P.isWord (plusPtr pos 1) end 0x2D {- - -}
                        then eatMultiCommentHelp start (plusPtr pos 2) end row (col + 2) (openComments + 1)
                        else
                          let !newPos = plusPtr pos (P.getCharWidth word)
                           in eatMultiCommentHelp start newPos end row (col + 1) openComments

-- DOCUMENTATION COMMENT

docComment :: (Row -> Col -> x) -> (E.Space -> Row -> Col -> x) -> P.Parser x Src.DocComment
docComment toExpectation toSpaceError =
  P.Parser $ \(P.State src pos end indent row col) cok _ cerr eerr ->
    let !pos3 = plusPtr pos 3
     in if pos3 <= end
          && P.unsafeIndex (pos) == 0x7B {- { -}
          && P.unsafeIndex (plusPtr pos 1) == 0x2D {- - -}
          && P.unsafeIndex (plusPtr pos 2) == 0x7C
          then
            let !col3 = col + 3

                (# status, newPos, newRow, newCol #) =
                  eatMultiCommentHelp pos3 pos3 end row col3 1
             in case status of
                  MultiGood _ ->
                    let !off = minusPtr pos3 (unsafeForeignPtrToPtr src)
                        !len = minusPtr newPos pos3 - 2
                        !snippet = P.Snippet src off len row col3
                        !comment = Src.DocComment snippet
                        !newState = P.State src newPos end indent newRow newCol
                     in cok comment newState
                  MultiTab -> cerr newRow newCol (toSpaceError E.HasTab)
                  MultiEndless -> cerr row col (toSpaceError E.EndlessMultiComment)
          else eerr row col toExpectation
