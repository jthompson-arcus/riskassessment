#' The UI for the 'Metric Box' module
#'
#' @param id a module id name
#' @keywords internal
#'
metricBoxUI <- function(id) {
  uiOutput(NS(id, "metricBox_ui"))
}

#' Server logic for the 'Metric Box' module
#'
#' @param id a module id name
#' @param title title.
#' @param desc description.
#' @param value metric value.
#' @param score metric score, as a character value
#' @param is_perc logical is the value is a percentage?
#' @param is_url  logical is the value a url
#' @param succ_icon icon used if is_true.
#' @param unsucc_icon icon used if not is_true.
#' @param icon_class string type of icon
#' @param type string to color the icon ("information" or "danger")
#'
#'
#' @import dplyr
#' @importFrom stringr str_sub str_extract
#' @importFrom glue glue
#' @importFrom bslib tooltip
#' @keywords internal
#'
metricBoxServer <- function(id, title, desc, value, score = "NULL",
                            is_perc = FALSE, is_url = FALSE,
                            succ_icon = "check", unsucc_icon = "triangle-exclamation",
                            icon_class = "text-success", type = "information"
                            ) {
  moduleServer(id, function(input, output, session) {

    metric <- dbSelect("select * from metric", db_name = golem::get_golem_options('assessment_db_name'))
    
    output$metricBox_ui <- renderUI({
      req(title, desc)

      # A str length of 41 chars tends to wrap to two rows and look quite nice
      val_max_nchar <- 31
      # is_true <- !(value %in% c("pkg_metric_error", "NA", "", "FALSE", NA))
      
      
      # logic for assessment values
      if (value %in% c("pkg_metric_error", "NA", NA)) {
        value <- "Not found"
        # if(score != "NULL") {score <- "NA"} # Shouldn't be needed
      } else if (is_perc) {
        value <- glue::glue("{round(as.numeric(value), 1)}%")
      } else if (is_url) {
        value <- a(ifelse(nchar(value) <= val_max_nchar, value,
          glue::glue("{stringr::str_sub(value, 1, (val_max_nchar - 3))}...")
        ), target = "_blank", href = value)
      } # unfortunately, adding the href can sometimes force the footer to fall
      # outside the card when val_max_nchar is too large.
      else if (value %in% c("TRUE", "FALSE")) {
        value <- ifelse(value == "TRUE", "Yes", "No")
      }

      
      # add asterisk to title if it is not in the metric table
      # skip databaseView cards
      title = if_else(stringr::str_extract(session$ns(id), "\\w+") != "databaseView" 
                      & !title %in% metric$long_name, paste0(title, "*"), title)

      
      # define some styles prior to building card
      card_style <- "max-width: 400px; max-height: 250px; padding-left: 5%; padding-right: 5%;" # overflow-y: scroll;
      auto_font_out <- auto_font(value,
        txt_max = val_max_nchar,
        size_min = .85, size_max = 1.5
      ) # , num_bins = 3
      body_p_style <- glue::glue("font-size: {auto_font_out}vw;")
      
      
      # Build the card's metric visual - either an icon or a meter
      if(score == "NULL" | # usually for non-riskmetric cards (like on comm or database tab)
         # riskmetric cards, both value and score must be missing to show an icon
         # if value is missing, but score isn't, then we need to show a meter
         # if score is missing, but value isn't, we need to show an NA meter
         (score == "NA" | is.na(score)) & any(unlist(value) %in% "Not found")) { # use icon version

        if (value == "Not found") { # For 'not found' cards
          display_obj <- icon(unsucc_icon,
                              class = "text-warning", verify_fa = FALSE,
                              style = "padding-top: 40%; font-size:60px; padding-left: 20%;"
          ) |> bslib::tooltip("Assessment not found, due to {riskmetric} source type")
          
        } else {  # usually for non-riskmetric cards
          display_obj <- icon(succ_icon,
                              class = icon_class, verify_fa = FALSE,
                              style = "padding-top: 40%; font-size:60px; padding-left: 20%;"
          )
        }
      } else { # use html version (displaying riskmetric score on a meter)
        display_obj <- div(style = "padding-top: 30%; padding-left: 10%;",
                           metric_gauge(score = score))
      }
      
      # Build HTML Card
      html_component <- div(
        class = "card mb-3 text-center border-info", style = card_style,
        div(
          class = "row no-gutters;",
          div(
            class = "col-md-4 text-center border-info",
            display_obj
          ),
          div(
            class = "col-md-8",
            h5(
              class = "card-header bg-transparent", style = "font-size: 1vw",
              title
            ),
            div(
              class = "card-body text-info",
              p(class = "card-title", style = c(body_p_style, if (!is_url) "white-space: pre-wrap;"), value)
            )
          ),
          div(class = "card-footer bg-transparent", desc)
        ))
     
      # Turn certain metric cards into hyperlinks that redirect to another tab (dependencies tab)
      if (title %in% c("Dependencies","Reverse Dependencies")){
        html_component <- shiny::tagAppendAttributes(
           html_component,
           style = "--cursor: pointer; cursor: var(--cursor)",
           onMouseOver="this.style['box-shadow'] = '2px 2px 2px black'",
           onMouseOut="this.style['box-shadow'] = 'none'",
           onclick = sprintf('(function () {
             Shiny.setInputValue("%s", new Date().getTime());
             }());', NS(id,"dep_click"))) |>
          bslib::tooltip("Click for more details", placement = "top")
      }
      else {
        html_component
      }
      if (type == "danger" & !is.na(type)) {
        html_component %>% 
          shiny::tagAppendAttributes(class = "text-danger", .cssSelector = "i") %>% 
          shiny::tagAppendAttributes(class = "text-danger", .cssSelector = "p")
      } else {
        html_component
      }
    })
  })
}
