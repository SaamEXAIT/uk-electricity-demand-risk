library(tidyverse)
library(lubridate)
# Historic ramps
ramps <- price_tsibble %>%
  arrange(datetime) %>%
  mutate(ramp_mw = demand_mw - lag(demand_mw)) %>%
  filter(!is.na(ramp_mw))

ramp_stats <- ramps %>%
  summarise(mean_ramp = mean(ramp_mw, na.rm=TRUE),
            median_ramp = median(ramp_mw, na.rm=TRUE),
            sd_ramp = sd(ramp_mw, na.rm=TRUE),
            q90 = quantile(ramp_mw,0.9, na.rm=TRUE),
            q95 = quantile(ramp_mw,0.95, na.rm=TRUE),
            q99 = quantile(ramp_mw,0.99, na.rm=TRUE))

write_csv(ramp_stats, "outputs/ramp_stats.csv")

# Recent 6-month ramps
source("03_residual_demand.R") # ensures df_rich, ldc_residual exist
compute_recent_ramps(price_tsibble, months_window = 6)
