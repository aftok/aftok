{-# LANGUAGE NoImplicitPrelude, TemplateHaskell #-}

module Quixotic where

import ClassyPrelude

import Control.Lens
import Network.Bitcoin (BTC)

newtype BtcAddr = BtcAddr { _address :: Text } deriving (Show, Eq, Ord)
makeLenses ''BtcAddr

parseBtcAddr :: Text -> Maybe BtcAddr
parseBtcAddr = Just . BtcAddr -- this will be changed to do validation

newtype UserId = UserId Int64 deriving (Show, Eq)
makePrisms ''UserId

newtype UserName = UserName Text deriving (Show, Eq)
makePrisms ''UserName

data User = User
  { _username :: UserName
  , _userAddress :: BtcAddr
  , _userEmail :: Text
  }
makeLenses ''User

newtype ProjectId = ProjectId Int64 deriving (Show, Eq)
makePrisms ''ProjectId

data Project = Project
  { _projectName :: Text
  , _inceptionDate :: UTCTime
  , _initiator :: UserId
  }
makeLenses ''Project

data Invitation = Invitation
  { _projectId :: ProjectId
  , _currentMember :: UserId
  , _sentAt :: UTCTime
  , _expiresAt :: UTCTime
  , _toAddr :: BtcAddr
  , _amount :: BTC
  }
makeLenses ''Invitation

newtype InvitationId = InvitationId Int64

data Acceptance = Acceptance
  { _acceptedInvitation :: InvitationId
  , _blockHeight :: Integer
  , _observedAt :: UTCTime
  }
makeLenses ''Acceptance
