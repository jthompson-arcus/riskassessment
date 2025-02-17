#' Create package database
#' 
#' @description Note: the database_name object is assigned by deployment users in R/run_app.R
#' 
#' @param db_name A string denoting the name of the database
#' 
#' @import dplyr
#' @importFrom DBI dbConnect dbDisconnect dbSendStatement dbClearResult
#' @importFrom RSQLite SQLite
#' @importFrom loggit loggit
#' @keywords internal
create_db <- function(db_name){
  
  if (missing(db_name) || is.null(db_name) || typeof(db_name) != "character" || length(db_name) != 1 || !grepl("\\.sqlite$", db_name))
    stop("db_name must follow SQLite naming conventions (e.g. 'database.sqlite')")
  
  # Create an empty database.
  con <- DBI::dbConnect(RSQLite::SQLite(), db_name)
  
  # Set the path to the queries.
  path <- app_sys("sql_queries") #file.path('sql_queries')
  
  # Queries needed to run the first time the db is created.
  queries <- c(
    "create_decision_table.sql",
    "create_package_table.sql",
    "create_metric_table.sql",
    "initialize_metric_table.sql",
    "create_package_metrics_table.sql",
    "create_community_usage_metrics_table.sql",
    "create_comments_table.sql",
    "create_roles_table.sql",
    "create_rules_table.sql"
  )
  
  # Append path to the queries.
  queries <- file.path(path, queries)
  
  # Apply each query.
  sapply(queries, function(x){
    
    tryCatch({
      rs <- DBI::dbSendStatement(
        con,
        paste(scan(x, sep = "\n", what = "character"), collapse = ""))
    }, error = function(err) {
      message <- paste("dbSendStatement",err)
      message(message, .loggit = FALSE)
      loggit::loggit("ERROR", message)
      DBI::dbDisconnect(con)
    })
    
    DBI::dbClearResult(rs)
  })
  
  DBI::dbDisconnect(con)
  invisible(db_name)
}



#' Create credentials database
#' 
#' Note: the credentials_db_name object is assigned by the deployment user in R/run_app.R
#' 
#' @param db_name A string denoting the name of the database
#' @param admin_role A string denoting the initialized privileges of the admin
#' 
#' @import dplyr
#' @importFrom DBI dbConnect dbDisconnect
#' @importFrom RSQLite SQLite
#' @importFrom shinymanager read_db_decrypt write_db_encrypt
#' @keywords internal
#' 
create_credentials_db <- function(db_name, admin_role = ""){
  
  if (missing(db_name) || is.null(db_name) || typeof(db_name) != "character" || length(db_name) != 1 || !grepl("\\.sqlite$", db_name))
    stop("db_name must follow SQLite naming conventions (e.g. 'credentials.sqlite')")
  
  # Init the credentials table for credentials database
  credentials <- data.frame(
    user = "ADMIN",
    password = "QWERTY1",
    # password will automatically be hashed
    admin = TRUE,
    expire = as.character(get_Date()),
    role = admin_role,
    stringsAsFactors = FALSE
  )
  
  # Init the credentials database
  shinymanager::create_db(
    credentials_data = credentials,
    sqlite_path = file.path(db_name), 
    passphrase = passphrase
  )
  
  # set pwd_mngt$must_change to TRUE
  con <- DBI::dbConnect(RSQLite::SQLite(), db_name)
  pwd <- shinymanager::read_db_decrypt(
    con, name = "pwd_mngt",
    passphrase = passphrase) %>%
    dplyr::mutate(must_change = ifelse(
      have_changed == "TRUE", must_change, as.character(TRUE)))
  
  shinymanager::write_db_encrypt(
    con,
    value = pwd,
    name = "pwd_mngt",
    passphrase = passphrase
  )
  DBI::dbDisconnect(con)
  
  # update expire date here to current date + 365 days
  con <- DBI::dbConnect(RSQLite::SQLite(), db_name)
  dat <- shinymanager::read_db_decrypt(con, name = "credentials", passphrase = passphrase) %>%
    dplyr::mutate(expire = as.character(get_Date() + 365))
  
  shinymanager::write_db_encrypt(
    con,
    value = dat,
    name = "credentials",
    passphrase = passphrase
  )
  
  DBI::dbDisconnect(con)
  invisible(db_name)
}

#' Create credentials dev database
#' 
#' @param db_name A string denoting the name of the database
#' 
#' @importFrom shinymanager create_db
#' @keywords internal
#' 
create_credentials_dev_db <- function(db_name){
  
  if (missing(db_name) || is.null(db_name) || typeof(db_name) != "character" || length(db_name) != 1 || !grepl("\\.sqlite$", db_name))
    stop("db_name must follow SQLite naming conventions (e.g. 'credentials.sqlite')")
  
  credential_config <- get_db_config("credentials")
  # Init the credentials table for credentials database
  if (is.null(credential_config)) {
    credentials <- data.frame(
      user = c("admin", "lead", "reviewer", "viewer"),
      password = rep("cxk1QEMYSpYcrNB", 4),
      # password will automatically be hashed
      admin = c(TRUE, FALSE, FALSE, FALSE),
      role = c("admin", "lead", "reviewer", "viewer"),
      stringsAsFactors = FALSE
    )
  } else {
    credentials <- data.frame(
      user = credential_config[["roles"]],
      password = rep("cxk1QEMYSpYcrNB", length(credential_config[["roles"]])),
      admin = credential_config[["roles"]] %in% credential_config[["privileges"]][["admin"]],
      role = credential_config[["roles"]],
      stringsAsFactors = FALSE
    )
  }
  
  # Init the credentials database
  shinymanager::create_db(
    credentials_data = credentials,
    sqlite_path = file.path(db_name), 
    passphrase = passphrase
  )
  
  invisible(db_name)
}

#' Initialize `riskassessment` Application Settings
#'
#' @description This sets up the environment when running the `riskassessment`
#'   Application. It sets the log file, initializes the package database if
#'   missing, and initializes the credentials database if missing.
#' 
#' @param assess_db A string denoting the name of the assessment database.
#' @param cred_db A string denoting the name of the credentials database.
#' @param configuration a list dictating the configuration of the databases
#'
#' @return There is no return value. The function is run for its side effects.
#' @importFrom loggit set_logfile
#'
#' @export
initialize_raa <- function(assess_db, cred_db, configuration) {
  if (isTRUE(getOption("shiny.testmode"))) return(NULL)
  
  db_config <- if(missing(configuration)) get_db_config(NULL) else configuration
  used_configs <- c("assessment_db", "credential_db", "decisions", "credentials", 
                    "loggit_json", "metric_weights", "report_prefs", 
                    "package_repo", "use_shinymanager", "inherits")
  if (any(!names(db_config) %in% used_configs)) {
    names(db_config) %>%
      `[`(!. %in% used_configs) %>%
      purrr::walk(~ warning(glue::glue("Unknown database configuration '{.x}' found in db-config.yml")))
  }
  
  use_shinymanager <- !isFALSE(db_config[["use_shinymanager"]])
  
  assessment_db <- if (missing(assess_db)) get_db_config("assessment_db") else assess_db
  if (use_shinymanager)
    credentials_db <- if (missing(cred_db)) golem::get_golem_options('credentials_db_name') else cred_db
  
  if (is.null(assessment_db) || typeof(assessment_db) != "character" || length(assessment_db) != 1 || !grepl("\\.sqlite$", assessment_db))
    stop("assess_db must follow SQLite naming conventions (e.g. 'database.sqlite')")
  if (use_shinymanager && !isTRUE(getOption("shiny.testmode")) && (is.null(credentials_db) || typeof(credentials_db) != "character" || length(credentials_db) != 1 || !grepl("\\.sqlite$", credentials_db)))
    stop("cred_db must follow SQLite naming conventions (e.g. 'database.sqlite')")
  
  # Start logging info.
  loggit_file <- get_db_config("loggit_json")
  if (isRunning()) loggit::set_logfile(loggit_file)

  # https://github.com/rstudio/fontawesome/issues/99
  # Here, we make sure user has a functional version of fontawesome
  fa_v <- packageVersion("fontawesome")
  if(fa_v == '0.4.0') warning(glue::glue("HTML reports will not render with {{fontawesome}} v0.4.0. You currently have v{fa_v} installed. If the report download failed, please install a stable version. We recommend v0.5.0 or higher."))
  
  check_repos(db_config[["package_repo"]])
  
  if (!dir.exists("tarballs")) dir.create("tarballs")
  
  if (file.exists(assessment_db) && (use_shinymanager && file.exists(credentials_db)))
    return(invisible(c(assessment_db, if (use_shinymanager) credentials_db)))
  
  check_credentials(db_config[["credentials"]])

  if (use_shinymanager && isFALSE(getOption("golem.app.prod")) && !is.null(golem::get_golem_options('pre_auth_user')) && !file.exists(credentials_db)) create_credentials_dev_db(credentials_db)

  # Create package db & credentials db if it doesn't exist yet.
  if(!file.exists(assessment_db)) create_db(assessment_db)
  if(use_shinymanager && !file.exists(credentials_db)) {
    admin_role <- db_config[["credentials"]][["privileges"]] %>%
      purrr::imap(~ if ("admin" %in% .x) .y) %>%
      unlist(use.names = FALSE) %>%
      `[`(1)
    create_credentials_db(credentials_db, admin_role)
  }
  
  decision_categories <- db_config[["decisions"]][["categories"]]
  decisions <- suppressMessages(dbSelect("SELECT decision FROM decision_categories", assessment_db))
  check_dec_cat(decision_categories)
  if (nrow(decisions) == 0) {
    configure_db(assessment_db, db_config)
  } else if (!identical(decisions$decision, decision_categories)) {
    stop("The decision categories in the configuration file do not match those in the assessment database.")
  }

  invisible(c(assessment_db, if (use_shinymanager) credentials_db))
}

#' Check CRAN repos
#' 
#' Checks that the package repositories provided in the configuration file are valid
#' 
#' @param repos A character vector containing the package repos
#' 
#' @noRd
check_repos <- function(repos) {
  if (!is.character(repos)) stop("The 'package_repo' configuration must be a character vector.")
  
  # `contrib.url()` is used to insure that appropriate subpages exist for the URL.
  good_urls <- 
    purrr::map_lgl(contrib.url(repos), ~ {
      dest <- tempfile()
      op <- options(warn = -1L)
      z <- tryCatch({
        download.file(url = paste0(.x, "/PACKAGES.rds"), 
                      destfile = dest, cacheOK = FALSE, 
                      quiet = TRUE, mode = "wb")
      }, error = identity)
      if (inherits(z, "error")) {
        z <- tryCatch({
          download.file(url = paste0(repos, "/PACKAGES.gz"), 
                        destfile = dest, cacheOK = FALSE, 
                        quiet = TRUE, mode = "wb")
        }, error = identity)
      }
      if (inherits(z, "error")) {
        z <- tryCatch({
          download.file(url = paste0(repos, "/PACKAGES"), 
                        destfile = dest, cacheOK = FALSE, 
                        quiet = TRUE, mode = "wb")
        }, error = identity)
      }
      options(op)
      unlink(dest)
      
      !inherits(z, "error")
    })
  
  if (any(!good_urls)) stop(glue::glue("The following URL{if (sum(!good_urls) > 1) 's' else ''} {if (sum(!good_urls) > 1) 'were' else 'was'} not reachable: {paste(contrib.url(repos[!good_urls]), collapse = ', ')}. Please check that the repo{if (sum(!good_urls) > 1) 's' else ''} {if (sum(!good_urls) > 1) 'are' else 'is'} valid and pointing to external sources."))
  
  invisible(repos)
}


#' The 'Add tags' function
#' 
#' @param ui placeholder
#' @param ... placeholder
#' 
#' 
#' @importFrom shinymanager fab_button
#' @importFrom shinyjs useShinyjs
#' @keywords internal
add_tags <- function(ui, ...) {
  ui <- force(ui)
  
  function(request) {
    query <- parseQueryString(request$QUERY_STRING)
    admin <- query$admin
    
    if (is.function(ui)) {
      ui <- ui(request)
    }
    
    if (identical(admin, "true")) {
      ui <- tagList(ui, 
                    tags$head(favicon(), bundle_resources(app_sys("app/www"), "riskassessment", "shinymanager_resources")),
                    tags$script(HTML("document.getElementById('admin-add_user').style.width = 'auto';")),
                    tags$script(HTML("var oldfab = Array.prototype.slice.call(document.getElementsByClassName('mfb-component--br'), 0);
                             for (var i = 0; i < oldfab.length; ++i) {
                               oldfab[i].remove();
                             }")),
                    shinymanager::fab_button(
                      position = "bottom-right",
                      actionButton(
                        inputId = ".shinymanager_logout",
                        label = "Logout",
                        icon = icon("right-from-bracket")
                      ),
                      actionButton(
                        inputId = ".shinymanager_app",
                        label = "Go to application",
                        icon = icon("share")
                      )
                    )
      )
    }
    
    tagList(shinyjs::useShinyjs(),
            ui,
            tags$script(HTML("$(document).on('shiny:value', function(event) {
                             if (event.target.id === 'admin-table_users') {
                             Shiny.onInputChange('table_users-returns', document.getElementById('admin-table_users').innerHTML)
                             } else if (event.target.id === 'admin-table_pwds') {
                             Shiny.onInputChange('table_pwds-returns', document.getElementById('admin-table_pwds').innerHTML)
                             }
                             });")))
  }
}

#' Add an Authentication Screen
#' 
#' Adds an authentication screen via [shinymanager::secure_app()].
#' 
#' @param app_ui The `app_ui` function for the application.
#' @param app_ver See identical param in [run_app()].
#' @param login_note See identical param in [run_app()].
#' 
#' @importFrom shinymanager secure_app
#' @importFrom golem get_golem_options
#' 
#' @md
#' @keywords internal
add_shinymanager_auth <- function(app_ui, app_ver, login_note) {
  # Don't add shinymanager if running the application in testing mode or without credentials
  if (!isTRUE(getOption("shiny.testmode")) && !isFALSE(get_db_config("use_shinymanager"))) {
  add_tags(shinymanager::secure_app(app_ui,
    tags_top = tags$div(
      tags$head(favicon(), tags$style(HTML(readLines(app_sys("app/www/css", "login_screen.css"))))),
      tags$head(if (isFALSE(getOption("golem.app.prod")) && !is.null(golem::get_golem_options("pre_auth_user"))) {
        tags$script(HTML(glue::glue("$(document).on('shiny:connected', function () {{
          Shiny.setInputValue('auth-user_id', '{golem::get_golem_options('login_creds')$user_id}');
          Shiny.setInputValue('auth-user_pwd', '{golem::get_golem_options('login_creds')$user_pwd}');
          $('#auth-go_auth').trigger('click');
        }});")))
      }),
      id = "login_screen",
      tags$h2("Risk Assessment Application", style = "align:center"),
      tags$h3(glue::glue("**Version {app_ver}**"),
        style = "align:center; color: darkgray"
      )
    ),
    tags_bottom = tags$div(
      tags$h6(login_note, style = "color: white")
    ),
    enable_admin = TRUE, theme = app_theme()
  ))
  } else {
    app_ui
  }
}


#' Application Theme
#'
#' @description This sets the `riskassessment` Application theme object using
#'   bslib's bs_theme() function. The app_theme object gets used in run_app.R,
#'   in addition to app_ui.R
#'
#' @return an bs_theme object of several classes
#' @importFrom bslib bs_theme
#'
#' @keywords internal
#' @export
app_theme <- function() {
  bslib::bs_theme(
    bootswatch = "lux",
    version = 5,
    primary = "#24305E",
    secondary = "#F76C6C",
  )
}
