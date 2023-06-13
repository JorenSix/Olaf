library(readr)
require(ggplot2)
require(svglite)

bm <- read_csv("olaf_memory_use.csv",show_col_types = FALSE);

a <- ggplot(bm, aes(bm$index_size, bm$memory_use)) +
  geom_point(na.rm = TRUE) +
  xlab("Indexed audio (s)") +
  ylab("Memory use (kB)") +
           theme_bw();
ggsave(file="olaf_memory_use.svg", plot=a, width=10, height=8)
