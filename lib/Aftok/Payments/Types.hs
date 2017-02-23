{-# LANGUAGE DeriveFoldable    #-}
{-# LANGUAGE DeriveFunctor     #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE ExplicitForAll    #-}
{-# LANGUAGE TemplateHaskell   #-}

module Aftok.Payments.Types where

import           ClassyPrelude

import           Control.Lens        (makeLenses, makePrisms, view)

import           Data.Thyme.Clock    as C
import           Data.Thyme.Time     as T
import           Data.UUID

import qualified Network.Bippy.Proto as P
import           Network.Bippy.Types (expiryTime, getExpires, getPaymentDetails)

import           Aftok.Billables     (Billable, Subscription, SubscriptionId)

newtype PaymentRequestId = PaymentRequestId UUID deriving (Show, Eq)
makePrisms ''PaymentRequestId

newtype PaymentId = PaymentId UUID deriving (Show, Eq)
makePrisms ''PaymentId

data PaymentRequest' s = PaymentRequest
  { _subscription       :: s
  , _paymentRequest     :: P.PaymentRequest
  , _paymentRequestTime :: C.UTCTime
  , _billingDate        :: T.Day
  } deriving (Functor, Foldable, Traversable)
makeLenses ''PaymentRequest'

type PaymentRequest = PaymentRequest' SubscriptionId

data Payment' r = Payment
  { _request     :: r
  , _payment     :: P.Payment
  , _paymentDate :: C.UTCTime
  } deriving (Functor, Foldable, Traversable)
makeLenses ''Payment'

type Payment = Payment' PaymentRequestId

type BillDetail = (PaymentRequestId, PaymentRequest, Subscription, Billable)

{- Check whether the specified payment request has expired (whether wallet software
 - will still consider the payment request valid)
 -}
isExpired :: forall s. C.UTCTime -> PaymentRequest' s -> Bool
isExpired now req =
  let check = any ((now >) . T.toThyme . expiryTime)
  -- using error here is reasonable since it would indicate
  -- a serialization problem
  in  either error (check . getExpires) $ getPaymentDetails (view paymentRequest req)

