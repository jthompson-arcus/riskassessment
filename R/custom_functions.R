is_gpl_license <- function(x) {
  grepl("GPL", x)
}

russian_roulette <- function(x) {
  sample(1:6, 1) == 1
}
