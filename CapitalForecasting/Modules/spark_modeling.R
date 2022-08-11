library(sparklyr)
library(dplyr)


# Sys.setenv(JAVA_HOME = "C:\\Program Files\\Java\\jdk-18.0.1.1")
# Sys.setenv(SPARK_HOME = "C:\\Users\\AxelTorbenson\\AppData\\Local\\spark\\spark-3.2.0-bin-hadoop3.2")


sc <- spark_connect(master = "local", version = "3.3")

google_gl <- spark_read_csv(sc, "C:\\Users\\AxelTorbenson\\OneDrive - eCapital Advisors, LLC\\Documents\\templates\\CapitalForecasting\\Data\\goog_gl.csv")


# seq() and sdf_seq() is not working for this
# quarter_1 <- sdf_seq(sc = sc, from = 1, to = 20, by = 4)
quarter_2 <- c(1, 5, 9, 13, 17, 21, 25)
quarter_3 <- c(2, 6, 10, 14, 18, 22, 26)
quarter_4 <- c(3, 7, 11, 15, 19, 23, 27)

gl <- google_gl %>%
  # period is a date proxy for lin reg
  arrange(fiscalDateEnding) %>% 
  sdf_with_sequential_id(id = "period", from = 1) %>% 
  select(
    # date and totals
    period,
    fiscalDateEnding,
    totalCurrentAssets,
    totalCurrentLiabilities,
    # assets
    inventory,
    cashAndCashEquivalentsAtCarryingValue, 
    currentNetReceivables,
    shortTermInvestments,
    otherCurrentAssets,
    # liabilities
    shortTermDebt,
    currentAccountsPayable,
    otherCurrentLiabilities) %>%
  mutate(workingCapital = totalCurrentAssets - totalCurrentLiabilities,
         otherCurrentAssets = totalCurrentAssets
         - inventory
         - cashAndCashEquivalentsAtCarryingValue
         - currentNetReceivables 
         - shortTermInvestments,
         # otherCurrentLiabilities includes taxes, deferred revenue, capital lease obligations, and other
         otherCurrentLiabilities = totalCurrentLiabilities
         - shortTermDebt 
         - currentAccountsPayable,
         # NA is equivalent to 0
         across(where(is.numeric), ~replace(., is.na(.), 0)),
         # Make data in millions
         across(c(3:13), .fns = ~./1000000),
         # Liabilities are negative
         across(c("shortTermDebt", "currentAccountsPayable", "otherCurrentLiabilities"), .fns = ~. * -1)) %>% 
  select(-workingCapital, -totalCurrentAssets, -totalCurrentLiabilities) %>% 
  pivot_longer(-c(fiscalDateEnding, period), values_to = "dollars") %>%
  group_by(name) %>%
  mutate(accountType = case_when(
    name %in% c(
      "inventory",
      "cashAndCashEquivalentsAtCarryingValue",
      "currentNetReceivables",
      "shortTermInvestments",
      "otherCurrentAssets"
    ) ~ "asset",
    name %in% c(
      "shortTermDebt",
      "currentAccountsPayable",
      "otherCurrentLiabilities"
    ) ~ "liability")
  ) %>% 
  mutate(period = as.numeric(period),
         # not using lags in lin reg right now, can't figure it out
         # lag_1 = lag(dollars, 1, order_by = fiscalDateEnding),
         # lag_2 = lag(dollars, 2, order_by = fiscalDateEnding),
         # lag_3 = lag(dollars, 3, order_by = fiscalDateEnding),
         q_2 = case_when(period %in% quarter_2 ~ 1, TRUE ~ 0),
         q_3 = case_when(period %in% quarter_3 ~ 1, TRUE ~ 0),
         q_4 = case_when(period %in% quarter_4 ~ 1, TRUE ~ 0))

prediction_data <- sdf_seq(sc = sc, from = 21, to = 24, by = 1) %>% 
  mutate(period = id,
         q_2 = case_when(id %in% quarter_2 ~ 1, TRUE ~ 0),
         q_3 = case_when(id %in% quarter_3 ~ 1, TRUE ~ 0),
         q_4 = case_when(id %in% quarter_4 ~ 1, TRUE ~ 0)) %>% 
  select(-id)

fit_model <- function(data, account_name, account_type, prediction_data) {
  df <- data %>% 
    filter(name == account_name) %>% 
    na.omit()
  model <- ml_linear_regression(df, dollars ~ period + q_2 + q_3 + q_4)
  ml_predict(model, prediction_data) %>% 
    mutate(name = account_name,
           accountType = account_type)
}

# assets
inventory_predictions <- fit_model(gl, "inventory", "asset", prediction_data)
cashAndCashEquivalentsAtCarryingValue_predictions <- fit_model(gl, "cashAndCashEquivalentsAtCarryingValue", "asset", prediction_data)
currentNetReceivables_predictions <- fit_model(gl, "currentNetReceivables", "asset", prediction_data)
shortTermInvestments_predictions <- fit_model(gl, "shortTermInvestments", "asset", prediction_data)
otherCurrentAssets_predictions <- fit_model(gl, "otherCurrentAssets", "asset", prediction_data)

# liabilities
shortTermDebt_predictions <- fit_model(gl, "shortTermDebt", "liability", prediction_data)
currentAccountsPayable_predictions <- fit_model(gl, "currentAccountsPayable", "liability", prediction_data)
otherCurrentLiabilities_predictions <- fit_model(gl, "otherCurrentLiabilities", "liability", prediction_data)


predictions <- sdf_bind_rows(inventory_predictions,
              cashAndCashEquivalentsAtCarryingValue_predictions,
              currentNetReceivables_predictions,
              shortTermInvestments_predictions,
              otherCurrentAssets_predictions,
              shortTermDebt_predictions,
              currentAccountsPayable_predictions,
              otherCurrentLiabilities_predictions) %>% 
  mutate(type = "forecast") %>% 
  rename(dollars = prediction)

full_df <- gl %>% 
  select(period, name, dollars, accountType, q_2, q_3, q_4) %>% 
  mutate(type = "actual") %>% 
  union_all(predictions)


spark_disconnect(sc)







