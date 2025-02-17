#' Assign decision rules based on risk score
#' 
#' Automates the decision for a package based upon the provided rules
#' 
#' @param rule_list A named list containing the decision rules
#' @param package A character string of the name of the package
#' 
#' @return A character string of the decision made
#' 
#' @noRd
#' 
#' @importFrom purrr map_lgl possibly
#' @importFrom rlang is_function is_formula
#' @importFrom glue glue
#' @importFrom loggit loggit
assign_decisions <- function(rule_list, package, db_name = golem::get_golem_options('assessment_db_name')) {
  # Checks if decision has already been made and skips assignment if the case
  decision <- dbSelect("SELECT decision_id FROM package WHERE name = {package}", db_name)[[1]]
  dec_rule <- NA_character_
  if (any(purrr::map_lgl(rule_list, ~ !is.na(.x$metric))))
    assessments <- get_assess_blob(package, db_name)
  
  for (i in seq_along(rule_list)) {
    if (!is.na(decision)) break
    rule <- rule_list[[i]]
    
    if (rlang::is_function(rule$mapper) || rlang::is_formula(rule$mapper))
      fn <- purrr::possibly(rule$mapper, otherwise = FALSE)
    if (rule$type == "overall_score") {
      decision <- if (fn(get_pkg_info(package)$score)) rule$decision else NA_character_
      log_message <- glue::glue("Decision for the package {package} was assigned {decision} because the risk score returned TRUE for `{rule$condition}`")
      db_message <- glue::glue("Decision was assigned '{decision}' by decision rules because the risk score returned TRUE for `{rule$condition}`")
    } else if (rule$type == "assessment" && (rlang::is_function(rule$mapper) | rlang::is_formula(rule$mapper))) {
      test <- try(fn(assessments[[rule$metric]][[1]]), silent = TRUE)
      decision <- if (is.logical(test) && length(test) == 1 && !is.na(test) && test) rule$decision else NA_character_
      log_message <- glue::glue("Decision for the package {package} was assigned {decision} because the {rule$metric} assessment returned TRUE for `{rule$condition}`")
      db_message <- glue::glue("Decision was assigned '{decision}' by decision rules because the {rule$metric} assessment returned TRUE for `{rule$condition}`")
    } else if (rule$type == "else") {
      decision <- rule$decision
      log_message <- glue::glue("Decision for the package {package} was assigned {decision} by default because all conditions were passed by the decision rules.")
      db_message <- glue::glue("Decision was assigned {decision} by default because all conditions were passed by the decision rules.")
    } else {
      warning(glue::glue("Unable to apply rule for {rule$metric}."))
      decision <- ""
    }
    
    if (is.na(decision)) next
    dec_rule <- paste("Rule", i)
    
    decision_id <- dbSelect("SELECT id FROM decision_categories WHERE decision = {decision}", db_name)
    dbUpdate("UPDATE package SET decision_id = {decision_id},
                        decision_by = 'Auto Assigned', decision_date = {get_Date()}
                         WHERE name = {package}",
             db_name)
    loggit::loggit("INFO", log_message)
    dbUpdate(
      "INSERT INTO comments
          VALUES ({package}, 'Auto Assigned', 'admin',
          {db_message}, 'o', {getTimeStamp()})",
      db_name)
  }
  
  list(decision = decision, decision_rule = dec_rule)
}

#' Get colors for decision categories
#' 
#' Gets the correct color palette based on the number of decision categories
#' 
#' @param decision_categories A vector containing the decision categories
#' 
#' @return A vector of colors for displaying the decision categories
#' 
#' @noRd
get_colors <- function(dbname) {
  dbname %>%
    dbSelect(query = "SELECT decision, color FROM decision_categories") %>%
    purrr::pmap(function(decision, color) {setNames(color, decision)}) %>% 
    unlist()
}

#' Get contrasting text color
#' 
#' Returns the color for the text based on provided background color
#' 
#' @param hex A string containing a hexidecimal
#' 
#' @return A hexidecimal corresponding to white or black
#' 
#' @noRd
get_text_color <- function(hex) {
  lum <-
    hex %>%
    stringr::str_remove("#") %>%
    purrr::map_dbl(
      ~ {
        .x %>%
          substring(0:2*2+1,1:3*2) %>%
          strtoi(16) %>%
          `*`(c(299, 587, 114)) %>%
          sum() 
      }) %>%
    `/`(1000)

  ifelse(lum <= 130, "#ffffff", "#000000")
}


#' Create risk decision label
#' 
#' Creates HTML friendly labels for the decision categories
#' 
#' @param x A character string containing the decision category
#' @param input A logical indicating whether to return an input ID for the category
#' 
#' @return A character string containing the generated label
#' 
#' @importFrom stringr str_replace_all regex
#' 
#' @noRd
risk_lbl <- function(x, type = c("input", "attribute", "module")) {
  type <- match.arg(type)
  lbl <- x %>% tolower() %>% 
    paste("cat", .) %>%
    stringr::str_replace_all(" +", "_") %>%
    stringr::str_replace_all(stringr::regex("[^a-zA-Z0-9_-]"), "")
  
  switch(
    type,
    input = lbl,
    attribute = paste(lbl, "attr", sep = "_"),
    module = paste(lbl, "mod", sep = "_")
  )
}

#' Process decision category table
#'
#' Process the decision category table from the assessment database for use
#' within the application
#'
#' @param db_name character name (and file path) of the assessment database
#'
#' @return A named list containing the lower and upper bounds for the risk
#'
#' @noRd
#' 
#' @importFrom purrr pmap set_names map compact
process_dec_tbl <- function(db_name = golem::get_golem_options('assessment_db_name')) {
  if (is.null(db_name))
    return(list())
  
  dec_tbl <- dbSelect("SELECT * FROM decision_categories", db_name)
  dec_tbl %>%
    purrr::pmap(function(lower_limit, upper_limit, ...) {c(lower_limit, upper_limit)}) %>% 
    purrr::set_names(dec_tbl$decision) %>%
    purrr::map(purrr::discard, is.na) %>%
    purrr::compact()
}

#' Process decision rules table
#'
#' Process the decision rules table from the assessment database for use within
#' the application
#'
#' @param db_name character name (and file path) of the assessment database
#'
#' @return A named list containing the ordered decision rules
#'
#' @noRd
#' 
#' @importFrom purrr pmap set_names map_chr
process_rule_tbl <- function(db_name = golem::get_golem_options('assessment_db_name')) {
  if (is.null(db_name))
    return(list())
  
   rule_tbl <- dbSelect("SELECT r.rule_type type, m.name metric, r.condition, d.decision FROM rules r LEFT JOIN metric m ON r.metric_id = m.id LEFT JOIN decision_categories d ON r.decision_id = d.id", db_name)
   rule_tbl %>%
     purrr::pmap(~ {
       out <- list(...) %>%
         within(mapper <- evalSetTimeLimit(parse(text = condition)))
     }) %>%
     purrr::set_names(purrr::imap_chr(., ~ switch(.x$type,
                                                  assessment = paste("rule", .y, sep = "_"), 
                                                  overall_score = risk_lbl(.x$decision, type = "module"), 
                                                  `else` = "rule_else")))
}

#' Create rule divs
#' 
#' Helper function to create the UI's associated with rule, metric, and decision category lists
#' 
#' @param rule_lst The ordered list of rules to create UI's for
#' @param metric_lst The named list of `{rismetric}` assessments
#' @param decision_lst The vector of allowable decision categories
#' @param ns The namespace the UI is being created inside of
#' 
#' @noRd
#' 
#' @importFrom purrr imap compact
create_rule_divs <- function(rule_lst, metric_lst, decision_lst, ns = NS(NULL)) {
  purrr::imap(rule_lst, ~ {
    if (isTRUE(.x == "remove")) return(NULL)
    
    if (.x$type == "assessment") {
      number <- strsplit(.y, "_")[[1]][2]
      mod_metric_rule_ui(ns("rule"), number, metric_lst, decision_lst, .x)
    } else if (.x$type == "overall_score") {
      mod_risk_rule_ui(ns(risk_lbl(.x$decision, type = "module")), risk_lbl(.x$decision, type = "module"))
    }
  }) %>%
    purrr::compact()
}

#' Create rule observer
#'
#' Helper function to create the "remove" rule observer that cleans up the
#' environment including the reactive rule list, moduels inputs and module
#' observers
#'
#' @param rv The reactive value associated with the module
#' @param rule_lst the reactive values that contains `rv`
#' @param .input The shiny input object from the environment the module was
#'   called inside of
#' @param ns The namespace of the module
#' @param session The session object passed to function given to `shinyServer`.
#'   Default is `getDefaultReactiveDomain()`
#'
#' @noRd
#' 
#' @importFrom shinyjs runjs
#' @importFrom glue glue
create_rule_obs <- function(rv, rule_lst, .input, ns = NS(NULL), session = getDefaultReactiveDomain()) {
  o <- observeEvent(rule_lst[[rv]], {
    req(isTRUE(rule_lst[[rv]] == "remove"))
    removeUI(glue::glue('[data-rank-id={rv}]'))
    remove_shiny_inputs(rv, .input, ns = ns)
    session$onFlushed(function() {
      shinyjs::runjs(glue::glue("Shiny.setInputValue('{ns(\"rules_order\")}:sortablejs.rank_list', $.map($('#{ns(\"rules_list\")}').children(), function(child) {{return $(child).attr('data-rank-id') || $.trim(child.innerText);}}))"))
    })
    rv_r6 <- .subset2(rule_lst, "impl")
    rv_r6$.values$remove(rv)
    rv_r6$.nameOrder = setdiff(rv_r6$.nameOrder, rv)
    o$destroy()
  })
}

#' Set evaluation time limit
#'
#' Sets a time limit on evaluation of an expression. This is a helper function
#' to allow users to add their own formulas or functions, which should have a
#' short evaluation time frame. This helps keep the application from getting
#' boggged down or for malicious code to be submitted.
#'
#' @param expr The expression to be evaluated
#' @param cpu,elapsed double (of length one). Set a limit on the total or
#'   elapsed cpu time in seconds, respectively.
#'
#' @noRd
evalSetTimeLimit <- function(expr, cpu = .25, elapsed = Inf) {
  setTimeLimit(cpu = cpu, elapsed = elapsed, transient = TRUE)
  on.exit({
    setTimeLimit(cpu = Inf, elapsed = Inf, transient = FALSE)
  })
  try(eval(expr), silent = TRUE)
}
