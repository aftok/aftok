{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeOperators #-}

-- | Public (unauthenticated) tip-jar API types and routes.
module Aftok.API.TipJar
  ( -- * API Types
    TipJarAPI,

    -- * Request/Response Types
    TipJarInfo (..),
    TipRequestBody (..),
    TipOutput (..),
    TipRequestResult (..),
  )
where

import Aftok.Types (ProjectId)
import Autodocodec (HasCodec (..), requiredField')
import qualified Autodocodec as AC
import Autodocodec.Aeson (parseJSONViaCodec, toJSONViaCodec)
import Data.Aeson (FromJSON (..), ToJSON (..))
import qualified Data.Aeson as A
import Servant.API

-- | Roster (GET) response: project name, count of eligible participants, and
-- the handles of the participants who have opted to show their handle.
data TipJarInfo = TipJarInfo
  { tjiProjectName :: Text,
    tjiParticipantCount :: Int,
    tjiNamedRecipients :: [Text]
  }
  deriving (Show, Generic)

instance HasCodec TipJarInfo where
  codec =
    AC.object "TipJarInfo" $
      TipJarInfo
        <$> requiredField' "projectName" AC..= tjiProjectName
        <*> requiredField' "participantCount" AC..= tjiParticipantCount
        <*> requiredField' "namedRecipients" AC..= tjiNamedRecipients

instance ToJSON TipJarInfo where toJSON = toJSONViaCodec

-- | Request (POST) body: the total amount the tipper wishes to send, in zatoshi.
newtype TipRequestBody = TipRequestBody {trbAmountZatoshi :: Word64}
  deriving (Show, Generic)

instance HasCodec TipRequestBody where
  codec =
    AC.object "TipRequestBody" $
      TipRequestBody
        <$> requiredField' "amountZatoshi" AC..= trbAmountZatoshi

instance FromJSON TipRequestBody where parseJSON = parseJSONViaCodec

-- | A single resolved output in a built tip request.
data TipOutput = TipOutput
  { toAddress :: Text,
    toAmountZatoshi :: Word64,
    toHandle :: Maybe Text
  }

-- | POST response: either a built ZIP 321 request, or a rejection because the
-- requested amount is too small for any eligible recipient to meet its
-- threshold. Encoded with a manual 'ToJSON' so the two cases are distinct.
data TipRequestResult
  = TipOk Text Word64 [TipOutput] Int
  | TipTooSmall Word64
  | TipNoRecipients

instance ToJSON TipRequestResult where
  toJSON (TipOk uri total outs elided) =
    A.object
      [ "zip321Uri" A..= uri,
        "totalZatoshi" A..= total,
        "outputs" A..= map outJSON outs,
        "elidedCount" A..= elided
      ]
    where
      outJSON (TipOutput a z h) =
        A.object $
          ["address" A..= a, "amountZatoshi" A..= z]
            ++ maybe [] (\hh -> ["handle" A..= hh]) h
  toJSON (TipTooSmall v) =
    A.object
      [ "error" A..= ("amount_too_small" :: Text),
        "minViableZatoshi" A..= v
      ]
  toJSON TipNoRecipients =
    A.object ["error" A..= ("no_recipients" :: Text)]

-- | Public tip-jar API: a roster GET and a build-a-payment POST.
type TipJarAPI =
  "projects" :> Capture "projectId" ProjectId :> "tip-jar" :> Get '[JSON] TipJarInfo
    :<|> "projects"
      :> Capture "projectId" ProjectId
      :> "tip-jar"
      :> "request"
      :> ReqBody '[JSON] TipRequestBody
      :> Post '[JSON] TipRequestResult
