{-# LANGUAGE TemplateHaskell #-}

module Aftok.Snaplet.Projects where

import ClassyPrelude 

import Control.Lens
import Control.Monad.State
import Data.Aeson as A
import Aftok
import Aftok.Database
import Aftok.Snaplet
import Aftok.Snaplet.Auth

import Snap.Core
import Snap.Snaplet
import Snap.Snaplet.PostgresqlSimple

data CreateProject = CreateProject { createProjectName :: Text }

instance FromJSON CreateProject where
  parseJSON (Object v) = CreateProject <$> v .: "projectName"
  parseJSON _ = mzero

projectCreateHandler :: Handler App App ProjectId
projectCreateHandler = do
  QDB{..} <- view qdb <$> with qm get
  uid <- requireUserId
  requestBody <- readRequestBody 4096
  cp <- maybe (snapError 400 "Could not parse project data") pure $ A.decode requestBody
  timestamp <- liftIO getCurrentTime
  liftPG . runReaderT . createProject $ Project (createProjectName cp) timestamp uid

projectListHandler :: Handler App App [QDBProject]
projectListHandler = do
  QDB{..} <- view qdb <$> with qm get
  uid <- requireUserId
  liftPG . runReaderT $ findUserProjects uid

projectGetHandler :: Handler App App Project
projectGetHandler = do
  QDB{..} <- view qdb <$> with qm get
  pid <- fmap snd requireProjectAccess
  mp <- liftPG . runReaderT $ findProject pid
  maybe (snapError 404 $ "Project not found for id " <> tshow pid) pure mp
