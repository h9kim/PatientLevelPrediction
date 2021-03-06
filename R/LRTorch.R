# @file LRTorch.R
#
# Copyright 2018 Observational Health Data Sciences and Informatics
#
# This file is part of PatientLevelPrediction
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

#' Create setting for logistics regression model with python 
#' @param w_decay      The l2 regularisation
#' @param seed       A seed for the model 
#' @param epochs     The number of epochs
#' @param class_weight   The class weight used for imbalanced data: 
#'                           0: Inverse ratio between positives and negatives
#'                          -1: Focal loss
#' @param autoencoder     First learn stakced autoencoder for input features, then train LR on the encoded features.
#' @param vae     First learn stakced varational autoencoder for input features, then train LR on the encoded features.
#' @examples
#' \dontrun{
#' model.lrTorch <- setLRTorch()
#' }
#' @export
setLRTorch <- function(w_decay=c(0.0005, 0.005), epochs=c(20, 50, 100), seed=NULL, 
                       class_weight = 0, autoencoder = FALSE, vae =FALSE){
  
  # test python is available and the required dependancies are there:
  checkPython()
  
  result <- list(model='fitLRTorch', param=split(expand.grid(w_decay=w_decay, epochs=epochs, 
                                           seed=ifelse(is.null(seed),'NULL', seed),  class_weight = class_weight, 
                                           autoencoder = autoencoder, vae = vae),
									       1:(length(w_decay)*length(epochs)) ),
                                     name='LR Torch')
  
  #result <- list(model='fitLRTorch', 
  #               param= c(size,epochs,seed),
  #               name='LR Torch')
  
  class(result) <- 'modelSettings' 
  
  return(result)
}

fitLRTorch <- function(population, plpData, param, search='grid', quiet=F,
                        outcomeId, cohortId, ...){
  
  # check plpData is libsvm format or convert if needed
  if(!'ffdf'%in%class(plpData$covariates))
    stop('Needs plpData')
  
  if(colnames(population)[ncol(population)]!='indexes'){
    warning('indexes column not present as last column - setting all index to 1')
    population$indexes <- rep(1, nrow(population))
  }
  
  # connect to python if not connected
  initiatePython()
  
  start <- Sys.time()
  
  population$rowIdPython <- population$rowId-1 # -1 to account for python/r index difference
  PythonInR::pySet('population', as.matrix(population[,c('rowIdPython','outcomeCount','indexes')]) )
  
  # convert plpData in coo to python:
  x <- toSparsePython(plpData,population, map=NULL)

  # save the model to outLoc  TODO: make this an input or temp location?
  outLoc <- file.path(getwd(),'python_models')
  # clear the existing model pickles
  for(file in dir(outLoc))
    file.remove(file.path(outLoc,file))
  
  #covariateRef$value <- unlist(varImp)
  # run model:
  outLoc <- file.path(getwd(),'python_models')
  PythonInR::pySet("modelOutput",outLoc)

  # do cross validation to find hyperParameter
  hyperParamSel <- lapply(param, function(x) do.call(trainLRTorch, c(x, train=TRUE)  ))

  
  hyperSummary <- cbind(do.call(rbind, param), unlist(hyperParamSel))
  
  #now train the final model
  bestInd <- which.max(abs(unlist(hyperParamSel)-0.5))[1]
  finalModel <- do.call(trainLRTorch, c(param[[bestInd]], train=FALSE))

  covariateRef <- ff::as.ram(plpData$covariateRef)
  incs <- rep(1, nrow(covariateRef)) 
  covariateRef$included <- incs
  covariateRef$covariateValue <- rep(0, nrow(covariateRef))
  
  modelTrained <- file.path(outLoc) 
  param.best <- param[[bestInd]]
  
  comp <- start-Sys.time()
  
  # return model location 
  result <- list(model = modelTrained,
                 trainCVAuc = -1, # ToDo decide on how to deal with this
                 hyperParamSearch = hyperSummary,
                 modelSettings = list(model='fitLRTorch',modelParameters=param.best),
                 metaData = plpData$metaData,
                 populationSettings = attr(population, 'metaData'),
                 outcomeId=outcomeId,
                 cohortId=cohortId,
                 varImp = covariateRef, 
                 trainingTime =comp,
                 dense=1,
                 covariateMap=x$map # I think this is need for new data to map the same?
                 
  )
  class(result) <- 'plpModel'
  attr(result, 'type') <- 'python'
  attr(result, 'predictionType') <- 'binary'
  
  return(result)
}


trainLRTorch <- function(epochs=100, w_decay = 0.001, seed=0, class_weight = 0, train=TRUE, autoencoder = FALSE, vae =FALSE){
  #PythonInR::pyExec(paste0("size = ",size))
  PythonInR::pyExec(paste0("epochs = ",epochs))
  PythonInR::pyExec(paste0("w_decay = ",w_decay))
  PythonInR::pyExec(paste0("class_weight = ",class_weight))
  PythonInR::pyExec("model_type = 'LogisticRegression'")
  python_dir <- system.file(package='PatientLevelPrediction','python')
  PythonInR::pySet("python_dir", python_dir)
  if (autoencoder | vae){
    PythonInR::pyExec("autoencoder = True")
    if (vae){
      PythonInR::pyExec("vae = True")
    } else {
      PythonInR::pyExec("vae = False")
    }
  } else {
    PythonInR::pyExec("autoencoder = False")
  }
  if(train)
    PythonInR::pyExec("train = True")
  if(!train)
    PythonInR::pyExec("train = False")
  
  # then run standard python code
  PythonInR::pyExecfile(system.file(package='PatientLevelPrediction','python','deepTorch.py'))
  
  if(train){
    # then get the prediction 
    pred <- PythonInR::pyGet('prediction', simplify = FALSE)
    pred <-  apply(pred,1, unlist)
    pred <- t(pred)
    colnames(pred) <- c('rowId','outcomeCount','indexes', 'value')
    pred <- as.data.frame(pred)
    attr(pred, "metaData") <- list(predictionType="binary")
    
    pred$value <- 1-pred$value
    auc <- PatientLevelPrediction::computeAuc(pred)
    writeLines(paste0('Model obtained CV AUC of ', auc))
    return(auc)
  }
  
  return(T)
  
}
