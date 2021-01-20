module Aftok.Snaplet.Json
  ( idJSON
  )
  where

import Control.Lens (Getter)
import Data.Aeson (Value, (.=))
import Data.UUID (UUID)

import Aftok.Json (idValue, obj, v1)

idJSON :: forall a. Text -> Getter a UUID -> a -> Value
idJSON t l a = v1 $ obj [t .= idValue l a]


