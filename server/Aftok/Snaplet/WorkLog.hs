{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}

module Aftok.Snaplet.WorkLog where

import Aftok.Database
import Aftok.Interval
  ( Interval (..),
    intervalJSON,
  )
import Aftok.Json
import Aftok.Project
import Aftok.Snaplet
import Aftok.Snaplet.Auth
import Aftok.Snaplet.Util
import Aftok.TimeLog
  ( AmendmentId,
    EventAmendment (..),
    EventId (..),
    FractionalPayouts,
    HasLogEntry (..),
    LogEntry,
    LogEvent,
    ModTime (..),
    Payouts (..),
    WorkIndex (..),
    _AmendmentId,
    _EventId,
    eventMeta,
    eventTime,
    payouts,
    toDepF,
    workIndex,
  )
import Aftok.Types
  ( CreditTo (..),
    _ProjectId,
    _UserId,
  )
import Aftok.Util (fromMaybeT)
import Control.Lens (Lens', (^.), _2, makePrisms)
import Control.Monad.Trans.Maybe (mapMaybeT)
import Data.Aeson ((.:), (.=), Value (Object), eitherDecode, object)
import Data.Aeson.Types (Parser, parseEither)
import qualified Data.List.NonEmpty as L
import qualified Data.Map.Strict as MS
import qualified Data.Text as T
import Data.Thyme.Clock as C
import Data.UUID as U
import Snap.Core
import Snap.Snaplet as S

logWorkHandler ::
  (C.UTCTime -> LogEvent) ->
  S.Handler App App (EventId, KeyedLogEntry)
logWorkHandler evCtr = do
  uid <- requireUserId
  pid <- requireProjectId
  requestBody <- readRequestBody 4096
  timestamp <- liftIO C.getCurrentTime
  case (eitherDecode requestBody >>= parseEither (parseLogEntry uid evCtr)) of
    Left err ->
      snapError 400 $
        "Unable to parse log entry "
          <> (show requestBody)
          <> ": "
          <> show err
    Right entry -> do
      eid <- snapEval $ createEvent pid uid (entry timestamp)
      ev <- snapEval $ findEvent eid
      maybe
        ( snapError 500 $
            "An error occured retrieving the newly created event record."
        )
        (pure . (eid,))
        ev

projectWorkIndex :: S.Handler App App (WorkIndex LogEntry)
projectWorkIndex = do
  uid <- requireUserId
  pid <- requireProjectId
  snapEval $ readWorkIndex pid uid

userEvents :: S.Handler App App [(EventId, LogEntry)]
userEvents = do
  uid <- requireUserId
  pid <- requireProjectId
  ival <- rangeQueryParam
  limit <- Limit . fromMaybe 1 <$> decimalParam "limit"
  snapEval $ findEvents pid uid ival limit

newtype UserEvent = UserEvent (EventId, LogEntry)
  deriving (Eq, Ord)

makePrisms ''UserEvent

instance HasLogEntry UserEvent where
  logEntry :: Lens' UserEvent LogEntry
  logEntry = _UserEvent . _2 . logEntry

userEventJSON :: UserEvent -> Value
userEventJSON (UserEvent (eid, le)) =
  object
    [ "eventId" .= idValue _EventId eid,
      "eventTime" .= (le ^. event . eventTime),
      "eventMeta" .= (le ^. eventMeta)
    ]

userWorkIndex :: S.Handler App App (WorkIndex UserEvent)
userWorkIndex = workIndex . fmap UserEvent <$> userEvents

payoutsHandler :: S.Handler App App FractionalPayouts
payoutsHandler = do
  uid <- requireUserId
  pid <- requireProjectId
  project <-
    fromMaybeT
      (snapError 400 $ "Project not found for id " <> show pid)
      (mapMaybeT snapEval $ findUserProject uid pid)
  widx <- snapEval $ readWorkIndex pid uid
  ptime <- liftIO $ C.getCurrentTime
  pure $ payouts (toDepF $ project ^. depf) ptime widx

amendEventResultJSON :: (EventId, AmendmentId) -> Value
amendEventResultJSON (eid, aid) =
  object
    [ "replacement_event" .= idValue _EventId eid,
      "amendment_id" .= idValue _AmendmentId aid
    ]

amendEventHandler :: S.Handler App App (EventId, AmendmentId)
amendEventHandler = do
  uid <- requireUserId
  eventIdBytes <- getParam "eventId"
  eventId <-
    maybe
      (snapError 400 "eventId parameter is required")
      (pure . EventId)
      (eventIdBytes >>= U.fromASCIIBytes)
  modTime <- ModTime <$> liftIO C.getCurrentTime
  requestJSON <- readRequestJSON 4096
  either
    (snapError 400 . T.pack)
    (snapEval . amendEvent uid eventId)
    (parseEither (parseEventAmendment modTime) requestJSON)

keyedLogEntryJSON :: (EventId, KeyedLogEntry) -> Value
keyedLogEntryJSON (eid, (pid, uid, ev)) =
  v1
    . obj
    $ [ "eventId" .= idValue _EventId eid,
        "projectId" .= idValue _ProjectId pid,
        "loggedBy" .= idValue _UserId uid
      ]
      <> logEntryFields ev

payoutsJSON :: FractionalPayouts -> Value
payoutsJSON (Payouts m) =
  v1 $
    let payoutsRec :: (CreditTo, Rational) -> Value
        payoutsRec (c, r) =
          object ["creditTo" .= creditToJSON c, "payoutRatio" .= r, "payoutPercentage" .= (fromRational @Double r * 100)]
     in obj $ ["payouts" .= fmap payoutsRec (MS.assocs m)]

workIndexJSON :: forall t. (t -> Value) -> WorkIndex t -> Value
workIndexJSON leJSON (WorkIndex widx) =
  v1 $
    obj ["workIndex" .= fmap widxRec (MS.assocs widx)]
  where
    widxRec :: (CreditTo, NonEmpty (Interval t)) -> Value
    widxRec (c, l) =
      object
        [ "creditTo" .= creditToJSON c,
          "intervals" .= (intervalJSON leJSON <$> L.toList l)
        ]

parseEventAmendment ::
  ModTime ->
  Value ->
  Parser EventAmendment
parseEventAmendment t = \case
  Object o ->
    let parseA :: Text -> Parser EventAmendment
        parseA "timeChange" = TimeChange t <$> o .: "eventTime"
        parseA "creditToChange" = CreditToChange t <$> parseCreditToV2 o
        parseA "metadataChange" = MetadataChange t <$> o .: "eventMeta"
        parseA tid =
          fail . T.unpack $ "Amendment type " <> tid <> " not recognized."
     in o .: "amendment" >>= parseA
  val ->
    fail $ "Value " <> show val <> " is not a JSON object."
