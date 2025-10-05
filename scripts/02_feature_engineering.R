library(tidyverse)
library(lubridate)
library(tsibble)
library(zoo)

df_features <- price_tsibble %>%
  mutate(
    date = as_date(datetime),
    hour_block = floor_date(datetime, "hour"),
    hour_frac = hour(datetime) + minute(datetime)/60,
    weekday = wday(datetime, label = TRUE, week_start = 1),
    month = month(datetime, label = TRUE),
    is_weekend = weekday %in% c("Sat","Sun"),
    quarter = quarter(datetime),
    week_of_year = isoweek(datetime),
    day_of_month = mday(datetime)
  ) %>%
  as_tsibble(index = datetime)

write_csv(df_features, "outputs/df_features.csv")
