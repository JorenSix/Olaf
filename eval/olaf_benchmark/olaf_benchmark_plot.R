library(readr)
require(ggplot2)
require(svglite)

bm <- read_csv("olaf_benchmark_result.csv",show_col_types = FALSE);

a <- ggplot(bm, aes(bm$seconds, bm$store_real_time)) +
  geom_point(na.rm = TRUE) +
  xlab("Indexed audio (s)") +
  ylab("Time to store (s)") +
          scale_x_log10(
                    breaks = scales::trans_breaks("log10", function(x) 10^x),
                    labels = scales::trans_format("log10", scales::math_format(10^.x))
                 ) +
          scale_y_log10(
                    breaks = scales::trans_breaks("log10", function(x) 10^x),
                     labels = scales::trans_format("log10", scales::math_format(10^.x))
                 ) +
           theme_bw();
a <- a + annotation_logticks();
ggsave(file="olaf_benchmark.svg", plot=a, width=10, height=8)


a <- ggplot(bm, aes(bm$seconds, bm$query_real_time)) +
  geom_point(na.rm = TRUE) +
  xlab("Indexed audio (s)") +
  ylab("Time to query (s)") +
          scale_x_log10(
                    breaks = scales::trans_breaks("log10", function(x) 10^x),
                    labels = scales::trans_format("log10", scales::math_format(10^.x))
                 ) +
           theme_bw();
a <- a + annotation_logticks();
ggsave(file="olaf_benchmark_query.svg", plot=a, width=10, height=8)