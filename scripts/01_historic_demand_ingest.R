# R Script for Enterprise-Level Workflow ----------------------------------

#Setup / configuration ------------------------------------------------
library(tidyverse)
library(lubridate)
library(tsibble)
library(zoo)
library(feasts)
library(fable)
library(boot) # for block bootstrap (tsboot)
library(DBI)
library(RPostgres) # or odbc::odbc()
library(glue)
library(scales)
library(ggplot2)


# 1 Reproducibility setup -------------------------------------------------------

SEED <- 2025

# Set base seed
set.seed(SEED)

# Parallel-safe RNG
RNGkind("L'Ecuyer-CMRG")

# Optional: helper function to log metadata
save_run_metadata <- function(file = "outputs/metadata_run.json") {
  if (!dir.exists(dirname(file))) dir.create(dirname(file), recursive = TRUE)
  meta <- list(
    seed = SEED,
    rngkind = RNGkind(),
    time = as.character(Sys.time()),
    R = R.Version()$version.string,
    session = capture.output(sessionInfo())
  )
  jsonlite::write_json(meta, file, pretty = TRUE, auto_unbox = TRUE)
  message("Run metadata saved to: ", file)
}

# Save metadata at script start (optional but best practice)
save_run_metadata()



file_path <- "historic_demand_2009_2024.csv"
df <- read_csv(file_path, col_types = cols())

# Harmonize columns & datetime
make_datetime_from_settlement <- function(date, period) {
  date + minutes(30) * (period - 1)
}

df <- df %>%
  rename(settlement_date = settlement_date,
         settlement_period = settlement_period,
         demand_mw = england_wales_demand) %>%
  mutate(settlement_date = as_date(settlement_date),
         datetime = make_datetime_from_settlement(settlement_date, settlement_period),
         demand_mw = as.numeric(demand_mw)) %>%
  group_by(datetime) %>%
  summarise(demand_mw = mean(demand_mw, na.rm = TRUE), .groups = "drop") %>%
  arrange(datetime)

# Create full 30-min tsibble
full_index <- seq(min(df$datetime), max(df$datetime), by = "30 min")
price_tsibble <- df %>%
  complete(datetime = full_index) %>%
  as_tsibble(index = datetime) %>%
  mutate(demand_mw = na.approx(demand_mw, na.rm = FALSE))

# Save preview
write_csv(df, "outputs/df_cleaned.csv")
write_csv(price_tsibble, "outputs/price_tsibble.csv")
