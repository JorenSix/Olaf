library(readr)
require(ggplot2)
require(svglite)

bm <- read_csv("olaf_memory_use.data",show_col_types = FALSE);

a <- ggplot(bm, aes(bm$index_size, bm$memory_use)) +
  geom_point(na.rm = TRUE) +
  xlab("Indexed audio (s)") +
  ylab("Memory use (kB)") +
  ylim(c(0,2500)) +
  theme()
ggsave(file="olaf_memory_use.svg", plot=a, width=10, height=8)
