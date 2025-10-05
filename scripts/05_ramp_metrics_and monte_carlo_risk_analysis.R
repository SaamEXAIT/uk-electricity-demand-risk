#Ramp Metrics & Monte Carlo Risk Analysis

# Computes:
# - Gross & residual ramps
# - Windowed statistics (1m,3m,6m,12m)
# - Directional quantiles & tail ratios
# - Daily extreme energy exposure (MWh)
# - Clustering & intraday heatmaps
# - Block bootstrap Monte Carlo VaR
# - Optional: price mapping for P&L VaR

compute_and_save_ramp_metrics <- function(df_rich,
                                          price_tsibble = NULL,
                                          outdir = "outputs",
                                          windows = c("1m","3m","6m","12m"),
                                          bootstrap_R = 1000,
                                          block_len = 48,
                                          hedge_capacity_mw = 1000,
                                          seed = 2025,
                                          save_csv = TRUE) {

  # ------------------------- Libraries --------------------------------------
  library(dplyr)
  library(lubridate)
  library(zoo)
  library(moments)
  library(readr)

  set.seed(seed)
  if(!dir.exists(outdir)) dir.create(outdir, recursive = TRUE)

  # ------------------------- Preconditions ----------------------------------
  stopifnot(all(c("datetime","demand_mw","res_demand_mw") %in% names(df_rich)))

  # ------------------------- Step 1: Compute Ramps ---------------------------
  df_rich2 <- df_rich %>%
    arrange(datetime) %>%
    mutate(
      gross_ramp_mw = demand_mw - lag(demand_mw),
      residual_ramp_mw = res_demand_mw - lag(res_demand_mw)
    ) %>%
    filter(!is.na(gross_ramp_mw) & !is.na(residual_ramp_mw))

  if(save_csv) write_csv(df_rich2 %>% select(datetime, gross_ramp_mw, residual_ramp_mw),
                         file.path(outdir, "df_rich2_ramps.csv"))

  # ------------------------- Helper Functions --------------------------------
  cvar_pos <- function(x, p=0.95) {
    v <- quantile(x, p, na.rm=TRUE)
    mean(x[x >= v], na.rm = TRUE)
  }

  cluster_stats <- function(series, threshold) {
    flag <- abs(series) > threshold
    if(all(!flag)) return(tibble(n_clusters=0, avg_cluster_len=0, max_cluster_len=0))
    r <- rle(flag)
    lens <- r$lengths[r$values]
    tibble(n_clusters=length(lens), avg_cluster_len=mean(lens), max_cluster_len=max(lens))
  }

  summarize_ramp <- function(vec) {
    v <- na.omit(vec)
    tibble(
      n = length(v),
      mean = mean(v), median = median(v), sd = sd(v),
      skew = ifelse(length(v)>2, skewness(v), NA_real_),
      kurt = ifelse(length(v)>3, kurtosis(v), NA_real_),
      q50 = quantile(v,0.5, na.rm=TRUE),
      q75 = quantile(v,0.75, na.rm=TRUE),
      q90 = quantile(v,0.90, na.rm=TRUE),
      q95 = quantile(v,0.95, na.rm=TRUE),
      q99 = quantile(v,0.99, na.rm=TRUE),
      p_exceed_q95 = mean(abs(v) >= quantile(abs(v),0.95,na.rm=TRUE)),
      ES_abs_95 = mean(abs(v)[abs(v) >= quantile(abs(v),0.95,na.rm=TRUE)], na.rm = TRUE)
    )
  }

  # ------------------------- Step 2: Windowed Metrics -----------------------
  window_map <- list("1m" = months(1), "3m" = months(3), "6m" = months(6), "12m" = months(12))
  metrics_rows <- list()
  now_max <- max(df_rich2$datetime, na.rm=TRUE)

  for(w in windows){
    win_start <- now_max - window_map[[w]]
    dfw <- df_rich2 %>% filter(datetime > win_start & datetime <= now_max)
    gross_sum <- summarize_ramp(dfw$gross_ramp_mw) %>% mutate(series="gross", window=w)
    resid_sum  <- summarize_ramp(dfw$residual_ramp_mw) %>% mutate(series="residual", window=w)
    metrics_rows[[w]] <- bind_rows(gross_sum, resid_sum)
  }

  metrics_all <- bind_rows(metrics_rows)
  if(save_csv) write_csv(metrics_all, file.path(outdir, "ramp_metrics_windows.csv"))

  # ------------------------- Step 3: Directional Quantiles & Tail Ratios ----
  win6 <- df_rich2 %>% filter(datetime > now_max - months(6))
  gross_pos_q <- quantile(win6$gross_ramp_mw[win6$gross_ramp_mw>0], c(.90,.95,.99), na.rm=TRUE)
  resid_pos_q  <- quantile(win6$residual_ramp_mw[win6$residual_ramp_mw>0], c(.90,.95,.99), na.rm=TRUE)
  gross_neg_q <- quantile(win6$gross_ramp_mw[win6$gross_ramp_mw<0], c(.10,.05,.01), na.rm=TRUE)
  resid_neg_q  <- quantile(win6$residual_ramp_mw[win6$residual_ramp_mw<0], c(.10,.05,.01), na.rm=TRUE)

  qtbl <- tibble(
    tail = c("q90_pos", "q95_pos", "q99_pos", "q10_neg","q05_neg","q01_neg"),
    gross = c(as.numeric(gross_pos_q), as.numeric(gross_neg_q)),
    residual = c(as.numeric(resid_pos_q), as.numeric(resid_neg_q))
  )
  if(save_csv) write_csv(qtbl, file.path(outdir, "ramp_directional_quantiles_6m.csv"))

  q95_gross_abs <- quantile(abs(win6$gross_ramp_mw), 0.95, na.rm=TRUE)
  q95_resid_abs  <- quantile(abs(win6$residual_ramp_mw), 0.95, na.rm=TRUE)
  q99_gross_abs <- quantile(abs(win6$gross_ramp_mw), 0.99, na.rm=TRUE)
  q99_resid_abs  <- quantile(abs(win6$residual_ramp_mw), 0.99, na.rm=TRUE)

  ratios <- tibble(
    metric = c("q95_abs","q99_abs"),
    gross = c(q95_gross_abs, q99_gross_abs),
    residual = c(q95_resid_abs, q99_resid_abs),
    resid_over_gross = c(q95_resid_abs/q95_gross_abs, q99_resid_abs/q99_gross_abs)
  )
  if(save_csv) write_csv(ratios, file.path(outdir, "ramp_tail_ratios_6m.csv"))

  # ------------------------- Step 4: Daily Extreme Energy --------------------
  extreme_events <- win6 %>% filter(abs(residual_ramp_mw) >= q95_resid_abs) %>%
    mutate(extreme_mwh = abs(residual_ramp_mw) * 0.5)
  daily_extreme <- extreme_events %>%
    mutate(date = as_date(datetime)) %>%
    group_by(date) %>%
    summarise(daily_extreme_mwh = sum(extreme_mwh, na.rm=TRUE),
              extreme_events = n()) %>%
    ungroup() %>%
    arrange(date) %>%
    mutate(cum_extreme_mwh = cumsum(daily_extreme_mwh))

  if(save_csv) write_csv(daily_extreme, file.path(outdir, "daily_extreme_mwh_6m.csv"))

  # ------------------------- Step 5: Cluster & Heatmaps ----------------------
  cluster_info <- cluster_stats(win6$residual_ramp_mw, q95_resid_abs)
  if(save_csv) write_csv(cluster_info, file.path(outdir, "residual_cluster_stats_6m.csv"))

  t_between <- diff(extreme_events$datetime)
  t_summary <- if(length(t_between)>0) tibble(
    mean_min_between = mean(as.numeric(t_between, units="mins")),
    median_min_between = median(as.numeric(t_between, units="mins")),
    sd_min_between = sd(as.numeric(t_between, units="mins"))
  ) else tibble(mean_min_between=NA, median_min_between=NA, sd_min_between=NA)
  if(save_csv) write_csv(t_summary, file.path(outdir, "time_between_extremes_6m.csv"))

  heat <- win6 %>% mutate(hour = hour(datetime), wday = wday(datetime, label=TRUE)) %>%
    mutate(exceed = abs(residual_ramp_mw) >= q95_resid_abs) %>%
    group_by(hour, wday) %>%
    summarise(freq = mean(exceed, na.rm=TRUE), n = n()) %>%
    ungroup()
  if(save_csv) write_csv(heat, file.path(outdir, "intraday_exceedance_heat_6m.csv"))

  # ------------------------- Step 6: Block Bootstrap Monte Carlo -------------
  bootstrap_blocks <- function(series, block_len=block_len, out_len=NULL){
    n <- length(series)
    blocks <- split(series, ceiling(seq_along(series)/block_len))
    if(is.null(out_len)) out_len <- n
    res <- numeric(0)
    while(length(res) < out_len) res <- c(res, blocks[[sample(length(blocks),1)]])
    res[1:out_len]
  }

  R <- bootstrap_R; h <- 7*48
  mc_q95 <- numeric(R); mc_max <- numeric(R); mc_uncovered_mwh <- numeric(R)

  for(i in seq_len(R)){
    sim <- bootstrap_blocks(win6$residual_ramp_mw, block_len = block_len, out_len = h)
    mc_q95[i] <- quantile(sim, 0.95, na.rm=TRUE)
    mc_max[i]  <- max(sim, na.rm=TRUE)
    uncovered_mw <- pmax(sim - hedge_capacity_mw, 0)
    mc_uncovered_mwh[i] <- sum(uncovered_mw) * 0.5
  }

  mc_summary <- tibble(
    mc_q95_median = median(mc_q95, na.rm=TRUE),
    mc_q95_p95 = quantile(mc_q95, 0.95, na.rm=TRUE),
    mc_max_p95 = quantile(mc_max, 0.95, na.rm=TRUE),
    VaR95_uncovered_mwh = quantile(mc_uncovered_mwh, 0.95, na.rm=TRUE)
  )

  if(save_csv) write_csv(mc_summary, file.path(outdir, "bootstrap_mc_summary_1week.csv"))

  # ------------------------- Step 7: Optional Price Mapping -----------------
  if(!is.null(price_tsibble)){
    stopifnot(all(c("datetime","price_mwh") %in% names(price_tsibble)))
    joined <- df_rich2 %>% 
      left_join(price_tsibble %>% select(datetime, price_mwh), by="datetime") %>%
      arrange(datetime) %>%
      mutate(price_delta = price_mwh - lag(price_mwh)) %>%
      filter(!is.na(price_delta))
    
    fit <- lm(price_delta ~ residual_ramp_mw + factor(hour(datetime)), data = joined)
    betar <- coef(fit)["residual_ramp_mw"]
    intercept <- ifelse(is.na(coef(fit)["(Intercept)"]), 0, coef(fit)["(Intercept)"])
    mc_price_q95 <- quantile(mc_q95 * betar + intercept, 0.95, na.rm=TRUE)

    if(save_csv) write_csv(tibble(price_impact_q95 = mc_price_q95),
                           file.path(outdir, "price_impact_q95_estimate.csv"))
  }

  # ------------------------- Step 8: Dashboard Row --------------------------
  dashboard_row <- tibble(
    as_of = Sys.time(),
    q95_resid = q95_resid_abs,
    q99_resid = q99_resid_abs,
    q95_gross = q95_gross_abs,
    q99_gross = q99_gross_abs,
    total_extreme_events_6m = nrow(extreme_events),
    total_extreme_mwh_6m = sum(extreme_events$extreme_mwh, na.rm = TRUE),
    VaR95_uncovered_mwh = mc_summary$VaR95_uncovered_mwh
  )
  if(save_csv) write_csv(dashboard_row, file.path(outdir, "dashboard_summary_today.csv"))

  # ------------------------- Return List -------------------------------------
  invisible(list(
    df_rich_ramps = df_rich2,
    metrics_all = metrics_all,
    quantile_table = qtbl,
    tail_ratios = ratios,
    daily_extreme = daily_extreme,
    mc_summary = mc_summary,
    dashboard_row = dashboard_row
  ))
}

# ========================= Example Call =====================================
# res <- compute_and_save_ramp_metrics(df_rich, price_tsibble = price_tsibble, bootstrap_R=1000, hedge_capacity_mw=1000)
