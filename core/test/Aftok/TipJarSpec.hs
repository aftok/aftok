{-# LANGUAGE ScopedTypeVariables #-}

module Aftok.TipJarSpec (main, spec) where

import Aftok.TipJar (Candidate (..), allocate, largestRemainder)
import qualified Data.Map.Strict as M
import Data.Ratio ((%))
import Test.Hspec (Spec, describe, hspec, it)
import Test.QuickCheck (Gen, choose, forAll, vectorOf)

main :: IO ()
main = hspec spec

genCands :: Gen [Candidate Int]
genCands = do
  n <- choose (1, 6)
  ws <- vectorOf n (choose (1, 100) :: Gen Integer)
  ts <- vectorOf n (choose (0, 50000) :: Gen Word64)
  pure [Candidate k (w % 1) t | (k, w, t) <- zip3 [0 ..] ws ts]

genTotal :: Gen Word64
genTotal = choose (1, 10000000)

genHardCands :: Gen [Candidate Int]
genHardCands = do
  n <- choose (1, 6)
  ws <- vectorOf n (choose (1, 100) :: Gen Integer)
  ts <- vectorOf n (choose (2, 50000) :: Gen Word64)
  pure [Candidate k (w % 1) t | (k, w, t) <- zip3 [0 ..] ws ts]

spec :: Spec
spec = do
  describe "largestRemainder" $
    it "sums to the total" $
      forAll genCands $ \cs -> forAll genTotal $ \t ->
        sum (largestRemainder (map candWeight cs) t) == t

  describe "allocate" $ do
    it "Right outputs sum to the total" $
      forAll genCands $ \cs -> forAll genTotal $ \t ->
        case allocate cs t of
          Right outs -> sum (map snd outs) == t
          Left _ -> True

    it "every Right output meets its threshold" $
      forAll genCands $ \cs -> forAll genTotal $ \t ->
        let thr = M.fromList [(candKey c, candThreshold c) | c <- cs]
         in case allocate cs t of
              Right outs -> all (\(k, a) -> a >= M.findWithDefault 0 k thr) outs
              Left _ -> True

    it "zero thresholds are always fundable" $
      forAll genCands $ \cs0 -> forAll genTotal $ \t ->
        let cs = [c {candThreshold = 0} | c <- cs0]
         in case allocate cs t of
              Right outs -> sum (map snd outs) == t
              Left _ -> False

    it "Left v implies the total was below v" $
      forAll genCands $ \cs -> forAll genTotal $ \t ->
        case allocate cs t of
          Left v -> t < v
          Right _ -> True

    it "reports an achievable minViable when nothing is fundable" $
      forAll genHardCands $ \cs ->
        case allocate cs 1 of
          Left v -> v > 1 && isRight (allocate cs v)
          Right _ -> True
