#!/bin/Rscript
print("Starting...")
library(glue)
library(tidyverse) 
library(MASS)
library(boot)
library(speedglm)
library(readr)
library(doParallel)
library(foreach)
library(caret)
library(e1071)
library(xgboost)
library(onehot)
#$//$ Define functions here: $//$


logloss<-function(predicted, actual)
{   #function to compute the Log-Loss
  
  # :param : actual- Ground truth (correct) 0-1 labels vector
  # :param : predicted- predicted values from the model
  # return: result- log-loss value
  result<- -1/length(actual)*(sum((actual*log(predicted)+(1-actual)*log(1-predicted))))
  return(result)
}
get_best_result = function(caret_fit) {
  best = which(rownames(caret_fit$results) == rownames(caret_fit$bestTune))
  best_result = caret_fit$results[best, ]
  rownames(best_result) = NULL
  best_result
}
important_features<-function(features, threshold){
  # returns all predictors with correlation less than threshold
  corr_matrix<-cor(features)
  columns<-rep(TRUE,nrow(corr_matrix))
  
  for(i in 1:length(columns) - 1){
    for(j in (i+1):length(columns)){
      if( length(corr_matrix[i,j]) > 0 && abs(corr_matrix[i,j])>= threshold){
        columns[j]<-FALSE
      }
    }
  }
  
  return (colnames(features)[columns])
}

convert_onehot<-function(x){
  input<-x
  trt_cnd = c('cp_type', 'cp_time', 'cp_dose')
  cp<-input[,trt_cnd]
  encoder<-onehot(cp)
  temp_onehot<-predict(encoder,cp)
  colnames(temp_onehot) <- c('type_ctl', 'type_cp', 'time_24', 'time_48', 'time_72', 'dose1', 'dose2')
  return(as_tibble(temp_onehot))
}


fix_names <- function(df) {
  names(df) <- gsub('-', '_', names(df))
  df
}

# path_why <- "./project498/MoA-498/"
path_why <- "/home/patel/project498/MoA-498/"

train_features <- read_csv(glue("{path_why}lish-moa/train_features.csv")) 
train_scores <- read_csv(glue("{path_why}lish-moa/train_targets_scored.csv"))
test_features_input <- read_csv(glue("{path_why}lish-moa/test_features.csv"))
sample_submission<-read_csv(glue("{path_why}lish-moa/sample_submission.csv"))
tSNE<-read_csv(glue("{path_why}lish-moa/tsne4dims.csv"))

set.seed(498)
test = sample(1:nrow(train_features), nrow(train_features)/10)
train = -test
train_y<-train_scores[train,] %>% dplyr::select(-sig_id)
predictors = names(train_y)

test_x_sig_id<-train_features[test,] %>% dplyr::select(sig_id)
test_features_sig_id<-test_features_input %>% dplyr::select(sig_id)

train_x<-train_features[train,] %>% dplyr::mutate(cp_type = factor(cp_type), cp_dose = factor(cp_dose), cp_time = factor(cp_time)) %>%dplyr::select(-sig_id)
test_x<-train_features[test,] %>% dplyr::mutate(cp_type = factor(cp_type), cp_dose = factor(cp_dose), cp_time = factor(cp_time)) %>% dplyr::select(-sig_id)
test_features<-test_features_input %>% dplyr::mutate(cp_type = factor(cp_type), cp_dose = factor(cp_dose), cp_time = factor(cp_time)) %>% dplyr::select(-sig_id)
#tSNE_train<-tSNE[train,]
#tSNE_test<-tSNE[test,]
test_y<-train_scores[test,]%>% dplyr::select(-sig_id)


#One-Hot encoding
train_x_onehot<-convert_onehot(train_x)
test_x_onehot<-convert_onehot(test_x)
test_features_onehot<-convert_onehot(test_features)

train_not_ctl = train_x_onehot$type_ctl != 1
test_not_ctl = test_x_onehot$type_ctl != 1
test_features_not_ctl = test_features_onehot$type_ctl != 1


train_x_g<-train_x%>%dplyr::select(starts_with('g-'))
train_x_c<-train_x%>%dplyr::select(starts_with('c-'))
test_x_g<-test_x%>%dplyr::select(starts_with('g-'))
test_x_c<-test_x%>%dplyr::select(starts_with('c-'))
test_feat_g<-test_features%>%dplyr::select(starts_with('g-'))
test_feat_c<-test_features%>%dplyr::select(starts_with('c-'))


print(glue("Starting PCA..."))
pca_g = preProcess(train_x_g, method = 'pca', thresh = 0.80)
pca_c = preProcess(train_x_c, method = 'pca', thresh = 0.80)
train_x_g<-predict(pca_g, train_x_g)
train_x_c<-predict(pca_c, train_x_c)
test_x_g<-predict(pca_g, test_x_g)
test_x_c<-predict(pca_c, test_x_c)
test_feat_g<-predict(pca_g, test_feat_g)
test_feat_c<-predict(pca_c, test_feat_c)
print(glue("Completed PCA!"))

names(train_x_g)<-glue("PCg-{c(1:length(train_x_g))}")
names(test_x_g)<-glue("PCg-{c(1:length(test_x_g))}")
names(test_feat_g)<-glue("PCg-{c(1:length(test_feat_g))}")

train_x_all<-(cbind(train_x_onehot, train_x_g, train_x_c) %>% as_tibble())[train_not_ctl,-c(1,2)]
test_x_all<-(cbind(test_x_onehot, test_x_g, test_x_c) %>% as_tibble())[,-c(1,2)]
test_features_all<-(cbind(test_features_onehot, test_feat_g, test_feat_c) %>% as_tibble())[,-c(1,2)]

# 
# cl<-makeCluster(4)
# registerDoParallel(cl)
# start_time<-Sys.time()
# print(glue("Started training models..."))
# 
# models<-foreach(i=1:length(predictors)  ,.packages=c("glue","dplyr","xgboost")) %dopar% {
#   train_y_predictor<-train_y[train_not_ctl,] %>% dplyr::select(predictors[i]) %>% unlist(use.names = FALSE)
#   datamatrix<-xgb.DMatrix(data = as.matrix(train_x_all), label = train_y_predictor)
#   xgboost(data = datamatrix, learning_rate=0.25, max_depth = 3, nrounds = 40, objective = 'binary:logistic', tree_method = 'gpu_hist')
# }
# end_time<-Sys.time()
# diff=difftime(end_time,start_time,units="secs")
# print(glue("Training Complete!"))
# print(glue("Time taken for training models: {diff} seconds."))
# stopCluster(cl)
# 
# 
# print(glue("Starting predictions on train data..."))
# train_preds<-foreach(i=1:length(predictors)  ,.packages=c("glue","dplyr","xgboost")) %do% {
#   pred<-predict(models[[i]],newdata = as.matrix(train_x_all))
# }
# print(glue("Prediction complete!\n"))

saveRDS(train_preds, "train_preds.rds")

cl<-makeCluster(10)
registerDoParallel(cl)
models_logistic<-foreach(i=1:length(predictors) , .packages=c("glue","dplyr","speedglm")) %dopar%{
  train_y_predictor<-train_y[train_not_ctl,] %>% dplyr::select(predictors[i]) %>% unlist(use.names = FALSE)
  speedglm(train_y_predictor~., data = data.frame(train_preds), family = binomial(), maxit = 50)
}
stopCluster(cl)

print(glue("Starting predictions..."))
preds_xgb<-foreach(i=1:length(predictors)  ,.packages=c("glue","dplyr","xgboost")) %do% {
  pred<-predict(models[[i]],newdata = as.matrix(test_x_all))
}
print(glue("Prediction complete!\n"))


print(glue("Starting predictions on test data..."))
preds_logreg<-foreach(i=1:length(predictors)  ,.packages=c("glue","dplyr","speedglm")) %do% {
  predict(models_logistic[[i]], newdata = list(`train_preds..i..` = preds_xgb), type= 'response')
}
print(glue("Prediction complete!\n"))




for(i in 1:length(preds)){
  preds[[i]][!test_not_ctl] = 0
}

print(glue("Starting logloss calculation..."))
loglosses<-foreach(i=1:length(predictors)  ,.packages=c("glue","dplyr","xgboost")) %do% {
  test_y_predictor<-test_y %>% dplyr::select(predictors[i]) %>% unlist(use.names = FALSE)

  temp <- pmax(pmin(as.numeric(preds[[i]]), 1 - 1e-15), 1e-15)
  logloss(temp,test_y_predictor)
}




#new_preds<-matrix(nrow = dim(test_x)[1], ncol = length(predictors))
#dimnames(new_preds) = list(test_x_sig_id %>% unlist(), predictors)
#new_preds<-data.frame(new_preds)
#for(i in 1:length(predictors)){
#  new_preds[i] = preds[[i]]
#}

#write_csv(new_preds,"preds_with_names.csv")



print(glue("Logloss on test data: {mean(loglosses%>%unlist())}\n"))

for(i in 1:length(predictors)){
  pred = predict(models[[i]] , newdata = as.matrix(test_features_all))
  pred[!test_features_not_ctl] = 0
  sample_submission[[predictors[i]]] = pred
}

write_csv(sample_submission, 'submission.csv')

print("End...")
