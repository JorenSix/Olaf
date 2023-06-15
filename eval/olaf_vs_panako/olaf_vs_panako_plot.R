library(readr)
require(ggplot2)
require(svglite)

bm <- read_csv("olaf_vs_panako.data",show_col_types = FALSE);

diffs = data.frame(diff(as.matrix(bm)))
index_steps = c(bm$index_size[1] , diffs$index_size )
bm$index_steps <- index_steps

a <- ggplot(bm, aes(bm$index_size,bm$olaf_query_time)) +
  geom_point(aes(x = bm$index_size , y = bm$olaf_query_time, colour="Olaf")) +
  geom_point(aes(x = bm$index_size, y = bm$panako_query_time, colour="Panako") , shape="triangle") +
  geom_point(na.rm = TRUE) +
  xlab("Indexed audio (s)") +
  ylab("Query time (s)") +
  ylim(c(0,150))+
  scale_color_manual(name='Query times',
                     breaks=c('Olaf', 'Panako'),
                     values=c('Olaf'='black', 'Panako'='steelblue'))+
  theme(legend.title=element_text(size=20),
        legend.text=element_text(size=14));


ggsave(file="olaf_vs_panako_query.svg", plot=a, width=10, height=8)
a