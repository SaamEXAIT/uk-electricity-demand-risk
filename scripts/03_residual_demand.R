library(tidyverse)
library(zoo)

df_rich <- df %>%
  select(datetime, demand_mw, embedded_wind_generation, embedded_solar_generation,
         ifa_flow, ifa2_flow, britned_flow, moyle_flow, east_west_flow,
         nemo_flow, nsl_flow, eleclink_flow, scottish_transfer,
         viking_flow, greenlink_flow, pump_storage_pumping) %>%
  complete(datetime = full_index) %>%
  arrange(datetime) %>%
  mutate(across(c(embedded_wind_generation, embedded_solar_generation, ends_with("_flow")),
                ~na.approx(.x, na.rm = FALSE)),
         pump_storage_pumping = replace_na(pump_storage_pumping, 0),
         res_gen_mw = embedded_wind_generation + embedded_solar_generation,
         interconnect_flow_mw = rowSums(across(ifa_flow:greenlink_flow), na.rm = TRUE),
         res_demand_mw = demand_mw - res_gen_mw + interconnect_flow_mw)

# Recent 6-month residual LDC
end_date <- max(price_tsibble$datetime)
start_date <- end_date - months(6)

ldc_residual <- df_rich %>%
  filter(datetime >= start_date & datetime <= end_date) %>%
  arrange(desc(res_demand_mw)) %>%
  mutate(rank = row_number())

write_csv(df_rich, "outputs/df_rich.csv")
write_csv(ldc_residual, "outputs/ldc_residual_6mo.csv")
