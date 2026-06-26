module Aftok.TipJar
  ( Candidate (..),
    allocate,
    largestRemainder,
  )
where

import Data.List (maximumBy, minimum)
import qualified Data.Set as Set

-- | A recipient candidate: an opaque key, a non-negative payout weight (the raw
-- share; weights need not sum to 1 — 'allocate' renormalizes), and a minimum
-- acceptable amount in zatoshi.
data Candidate k = Candidate
  { candKey :: k,
    candWeight :: Rational,
    candThreshold :: Word64
  }
  deriving (Show)

-- | Hamilton / largest-remainder apportionment of @total@ by @weights@.
-- The result has the same length as @weights@ and sums to exactly @total@.
-- If all weights are zero, distributes as evenly as possible.
largestRemainder :: [Rational] -> Word64 -> [Word64]
largestRemainder weights total
  | n == 0 = []
  | w <= 0 = evenSplit
  | otherwise = result
  where
    n = length weights
    w = sum weights
    t = toInteger total
    exacts = map (\wi -> fromInteger t * wi / w) weights
    floorsI = map floor exacts :: [Integer]
    remainder = t - sum floorsI -- 0 <= remainder < n
    fracs = zipWith (\e f -> e - fromInteger f) exacts floorsI
    order = map fst . sortBy (comparing (Down . snd)) $ zip [0 :: Int ..] fracs
    bumpSet = Set.fromList (take (fromInteger remainder) order)
    result =
      zipWith
        (\i f -> fromInteger (f + if i `Set.member` bumpSet then 1 else 0))
        [0 :: Int ..]
        floorsI
    evenSplit =
      let base = t `div` toInteger n
          r = t - base * toInteger n
       in zipWith (\i _ -> fromInteger (base + if toInteger i < r then 1 else 0)) [0 :: Int ..] weights

-- | Split @total@ zatoshi across the candidates by weight, dropping any whose
-- allocation would fall below its threshold (iteratively: remove the worst
-- sub-threshold offender, renormalize, retry) using largest-remainder rounding
-- so outputs sum to exactly @total@. Returns @Left minViable@ when no candidate
-- can be funded at or above its threshold, where @minViable@ is the smallest
-- total at which at least one candidate (at its full-set share) would qualify.
allocate :: [Candidate k] -> Word64 -> Either Word64 [(k, Word64)]
allocate cands0 total = go (zip [0 :: Int ..] cands0)
  where
    go [] = Left (minViable cands0)
    go indexed =
      let amounts = largestRemainder (map (candWeight . snd) indexed) total
          paired = zip indexed amounts
          under = [p | p@((_, c), amt) <- paired, amt < candThreshold c]
       in if null under
            then Right [(candKey c, amt) | ((_, c), amt) <- paired]
            else
              let ((worstIx, _), _) =
                    maximumBy (comparing (\((_, c), amt) -> candThreshold c - amt)) under
               in go [ic | ic@(i, _) <- indexed, i /= worstIx]

    minViable :: [Candidate k] -> Word64
    minViable cs =
      case [c | c <- cs, candWeight c > 0] of
        [] -> maxBound
        positives ->
          let w = sum (map candWeight positives)
           in minimum
                [ceiling (fromIntegral (candThreshold c) * w / candWeight c) | c <- positives]
