{-# LANGUAGE ScopedTypeVariables, OverloadedStrings, NoImplicitPrelude #-}
{-# LANGUAGE TemplateHaskell #-}

module Quixotic.Database.SQLite (sqliteQDB) where

import ClassyPrelude
import Control.Lens
import Data.Hourglass
import Database.SQLite.Simple
import Database.SQLite.Simple.ToField
import qualified Text.Read as R

import Quixotic
import Quixotic.Auction
import Quixotic.Database
import Quixotic.TimeLog
import Quixotic.Users

newtype PLogEntry = PLogEntry LogEntry
makePrisms ''PLogEntry

instance ToRow PLogEntry where
  toRow (PLogEntry (LogEntry a e)) = 
    toRow (a ^. address, e ^. (eventType . to eventName), e ^. eventTime)

instance FromRow PLogEntry where
  fromRow = 
    let workEventParser = WorkEvent <$> (field >>= nameEvent) <*> field 
        logEntryParser  = LogEntry <$> (fmap BtcAddr field) <*> workEventParser 
    in  fmap PLogEntry logEntryParser

newtype PAuction = PAuction Auction
makePrisms ''PAuction

instance FromRow PAuction where
  fromRow = 
    let auctionParser = Auction <$> fmap R.read field <*> field
    in  fmap PAuction auctionParser

newtype PBid = PBid Bid
makePrisms ''PBid

instance FromRow PBid where
  fromRow = 
    let bidParser = Bid <$> fmap UserId field <*> fmap Seconds field <*> fmap R.read field <*> field
    in  fmap PBid bidParser

newtype PSeconds = PSeconds Seconds

instance ToField PSeconds where 
  toField (PSeconds (Seconds i)) = toField i

newtype PUserId = PUserId UserId

instance ToField PUserId where 
  toField (PUserId (UserId i)) = toField i

newtype PAuctionId = PAuctionId AuctionId

instance ToField PAuctionId where 
  toField (PAuctionId (AuctionId i)) = toField i

-- TODO: Record the user id
recordEvent' :: UserId -> LogEntry -> ReaderT Connection IO ()
recordEvent' _ logEntry = do 
  conn <- ask
  lift $ execute conn 
    "INSERT INTO work_events (btc_addr, event_type, event_time) VALUES (?, ?, ?)" 
    (logEntry ^. (from _PLogEntry))

readWorkIndex' :: ReaderT Connection IO WorkIndex
readWorkIndex' = do
  conn <- ask
  rows <- lift $ query_ conn
    "SELECT btc_addr, event_type, event_time from work_events" 
  lift . pure . workIndex $ fmap (^. _PLogEntry) rows

newAuction' :: Auction -> ReaderT Connection IO AuctionId
newAuction' auc = do
  conn <- ask
  lift $ execute conn
    "INSERT INTO auctions (raise_amount, end_time) VALUES (?, ?)"
    (show $ auc ^. raiseAmount, auc ^. auctionEnd)
  lift . fmap AuctionId $ lastInsertRowId conn

readAuction' :: AuctionId -> ReaderT Connection IO (Maybe Auction)
readAuction' aucId = do
  conn <- ask
  rows <- lift $ query conn
    "SELECT raise_amount, end_time FROM auctions WHERE ROWID = ?" 
    (Only $ PAuctionId aucId)
  lift . return . headMay $ fmap (^. _PAuction) rows

recordBid' :: AuctionId -> Bid -> ReaderT Connection IO ()
recordBid' aucId bid = do
  conn <- ask
  lift $ execute conn
    "INSERT INTO bids (auction_id, user_id, bid_seconds, bid_amount, bid_time) values (?, ?, ?, ?, ?)"
    ( PAuctionId aucId
    , PUserId $ bid ^. bidUser
    , PSeconds $ bid ^. bidSeconds
    , show $ bid ^. bidAmount
    , bid ^. bidTime
    )

readBids' :: AuctionId -> ReaderT Connection IO [Bid]
readBids' aucId = do
  conn <- ask
  rows <- lift $ query conn
    "SELECT user_id, bid_seconds, bid_amount, bid_time FROM bids WHERE auction_id = ?"
    (Only $ PAuctionId aucId)
  lift . return $ fmap (^. _PBid) rows

createUser' :: User -> ReaderT Connection IO UserId
createUser' u = do
  conn <- ask
  lift $ execute conn
    "INSERT INTO users (btc_addr, email) VALUES (?, ?)"
    (u ^. (userAddress . address), u ^. userEmail)
  lift . fmap UserId $ lastInsertRowId conn

sqliteQDB :: QDB (ReaderT Connection IO)
sqliteQDB = QDB 
  { recordEvent = recordEvent'
  , readWorkIndex = readWorkIndex' 
  , newAuction = newAuction'
  , readAuction = readAuction'
  , recordBid = recordBid'
  , readBids = readBids'
  , createUser = createUser'
  , findUser = \_ -> pure Nothing
  , findUserByHandle = \_ -> pure Nothing
  }
