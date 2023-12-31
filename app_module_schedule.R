# paths module server
module_schedule_server <- function(input, output, session, data) {

  # namespace
  ns <- session$ns

  # constants
  data_err_prefix <- "Encountered database issue, the app may not function properly: "

  # reactive vaalues
  values <- reactiveValues(
    first_term = NULL,
    last_term = NULL
  )

  # data functions ===========

  # available terms
  get_terms <- reactive({
    validate(need(data$schedule$get_data(), "something went wrong retrieving the data"))
    get_available_terms(first_term = data$schedule$get_data()$term[1])
  })

  # monitor terms
  observeEvent(input$first_term, {
    if (is.null(values$first_term) || !identical(values$first_term, input$first_term))
      values$first_term <- input$first_term
  })
  observeEvent(input$last_term, {
    if (is.null(values$last_term) || !identical(values$last_term, input$last_term))
      values$last_term <- input$last_term
  })

  # selected terms
  get_selected_terms <- reactive({
    req(get_terms())
    req(values$first_term)
    req(values$last_term)
    terms <- get_terms() |> filter_terms(values$first_term, values$last_term)

    # include summers?
    if (!"Summers" %in% input$show_options) {
      terms <- terms |> drop_summers()
    }
    return(terms)
  })

  # classes
  get_classes <- reactive({
    req(data$classes$get_data())
    data$classes$get_data() |>
      # not teaching placeholder
      dplyr::bind_rows(dplyr::tibble(class = "XXXX0000", title = "not teaching placeholder")) |>
      # future classes placeholder
      dplyr::bind_rows(dplyr::tibble(class = "XXXX9999", title = "future classes placeholder")) |>
      dplyr::mutate(
        class = stringr::str_remove_all(.data$class, "[ \\r\\n]"),
        inactive = !is.na(.data$inactive) & .data$inactive,
        class = forcats::as_factor(.data$class)
      )
  })

  # instructors
  get_instructors <- reactive({
    req(data$instructors$get_data())
    data$instructors$get_data() |>
      dplyr::mutate(
        instructor_id = stringr::str_remove_all(.data$instructor_id, "[ \\r\\n]"),
        inactive = !is.na(.data$inactive) & .data$inactive
      )
  })

  # not teaching
  get_not_teaching <- reactive({
    req(data$not_teaching$get_data())
    req(get_instructors())
    not_teaching <- data$not_teaching$get_data()
    if (nrow(missing <- not_teaching |> dplyr::anti_join(get_instructors(), by = "instructor_id")) > 0) {
      msg <- sprintf("missing instructor_id in 'not_teaching': %s", paste(unique(missing$instructor_id), collapse = ", "))
      log_error(ns = ns, msg, user_msg = paste0(data_err_prefix, msg))
    }
    if (nrow(wrong <- not_teaching |> dplyr::filter(!stringr::str_detect(.data$term, get_term_regexp()))) > 0) {
      msg <- sprintf("incorrect term formatting in 'not_teaching': %s", paste(unique(wrong$term), collapse = ", "))
      log_error(ns = ns, msg, user_msg = paste0(data_err_prefix, msg))
    }
    not_teaching
  })

  # reasons
  get_reasons <- reactive({
    req(get_not_teaching())
    get_not_teaching()$reason |> unique() |> na.omit()
  })

  # schedule
  get_schedule <- reactive({
    req(data$schedule$get_data())
    req(get_terms())
    req(get_instructors())
    req(get_classes())
    req(get_not_teaching())

    # safety checks
    schedule <- data$schedule$get_data() |>
      # note that this is an experimental function in tidyr
      tidyr::separate_longer_delim("instructor_id", delim = ",") |>
      dplyr::mutate(
        class = stringr::str_remove_all(class, "[ \\r\\n]"),
        instructor_id = stringr::str_remove_all(instructor_id, "[ \\r\\n]"),
        canceled = !is.na(.data$canceled) & .data$canceled,
        deleted = !is.na(.data$deleted) & .data$deleted
      ) |>
      dplyr::mutate(
        instructor_id = ifelse(!is.na(instructor_id) & nchar(instructor_id) > 0,
                               instructor_id, "none")
      )

    # filter out canceled classes
    if (!"Canceled" %in% input$show_options) {
      schedule <- schedule |> dplyr::filter(!.data$canceled)
    }

    if (nrow(missing <- schedule |> dplyr::anti_join(get_instructors(), by = "instructor_id")) > 0) {
      msg <- sprintf("unrecognized `instructor_id` in `schedule`: '%s'", paste(unique(missing$instructor_id), collapse = "', '"))
      log_error(ns = ns, msg, user_msg = paste0(data_err_prefix, msg))
    }

    if (nrow(missing <- schedule |> dplyr::anti_join(get_classes(), by = "class")) > 0) {
      msg <- sprintf("unrecognized `class` in `classes`: '%s'", paste(unique(missing$class), collapse = "', '"))
      log_error(ns = ns, msg, user_msg = paste0(data_err_prefix, msg))
    }

    if (nrow(wrong <- schedule |> dplyr::filter(!stringr::str_detect(.data$term, get_term_regexp()))) > 0) {
      msg <- sprintf("incorrect term formatting in `schedule`: %s", paste(unique(wrong$term), collapse = ", "))
      log_error(ns = ns, msg, user_msg = paste0(data_err_prefix, msg))
    }

    # schedule with unique ID (for editing purposes)
    schedule |>
      dplyr::mutate(
        id = dplyr::row_number(),
        .before = 1L
      )
  })

  # schedule for data table
  get_schedule_for_table <- reactive({
    req(get_schedule())
    req(get_not_teaching())
    req(get_instructors())
    req(get_classes())
    req(get_selected_terms())

    # always reset visible columns to load new selection
    schedule$reset_visible_columns()

    # combine schedule information
    combine_schedule(
      schedule = get_schedule(),
      not_teaching = get_not_teaching(),
      instructors = get_instructors(),
      classes = get_classes(),
      available_terms = get_terms(),
      selected_terms = get_selected_terms(),
      recognized_reasons = get_reasons(),
      include_section_nr = "Section #" %in% input$show_options,
      include_day_time = "Day/Time" %in% input$show_options,
      include_location = "Location" %in% input$show_options,
      include_enrollment = "Enrollment" %in% input$show_options
    ) |>
      # select columns here to get proper order (instead of later, since the cols are dynamic depending on terms)
      dplyr::select(full_title, Instructor = instructor, dplyr::matches(get_term_regexp())) |>
      # escape html characters for safety and then create \n as <br>
      dplyr::mutate(dplyr::across(dplyr::where(is.character), function(x) {
        x |> htmltools::htmlEscape() |> stringr::str_replace_all("\\n", "<br>")
      }))
  })

  # generate UI =====================

  # sidebar GUI
  output$sidebar <- renderUI({
    req(get_terms())
    log_info("loading terms")
    terms <- get_terms() |> drop_summers()
    tagList(
      selectizeInput(
        ns("first_term"), "Select first term to display:",
        multiple = FALSE,
        choices = get_sorted_terms(terms),
        selected =
          isolate({
            if (!is.null(values$first_term) && values$first_term %in% as.character(terms)) values$first_term
            else "Spring 2024"#FIXME: temp solution for faculty feedback find_term(get_terms(), years_shift = -2)
          })
      ),
      selectizeInput(
        ns("last_term"), "Select last term to display:",
        multiple = FALSE,
        choices = get_sorted_terms(terms),
        selected =
          isolate({
            if (!is.null(values$last_term) && values$last_term %in% as.character(terms)) values$last_term
            else find_term(get_terms(), years_shift = +2)
          })
      ),
      checkboxGroupInput(
        ns("show_options"), "Select information to display:",
        choices = c("Summers", "Canceled", "Section #", "Day/Time", "Location", "Enrollment"),
        selected = c("Day/Time", "Location", "Enrollment")
        #, inline = TRUE
      )
    )
  })

  # main GUI
  output$main <- renderUI({
    tagList(
      shinydashboard::box(
        title =
          span(
            "Schedule",
            # div(
            #   style = "position: absolute; right: 10px; top: 5px;",
            #   module_selector_table_deselect_all_button(ns("classes"), border = FALSE),
            #   actionButton(ns("check"), "Check", icon = icon("check"), style = "border: 0;") |>
            #     add_tooltip("Check selected classes for fulfillment of degree requirements (degree audit)."),
            # )
          ), width = 12,
        status = "info", solidHeader = TRUE,
        module_selector_table_ui(ns("schedule")),
        footer = tagList("Use the search bar in the upper right to filter the schedule (e.g. by instructor name, course number, etc.). Use the scrollbar to scroll through all results.")
      )
    )
  })

  # check for selected terms
  observeEvent(
    get_selected_terms(),
    {
      shinyjs::hide("schedule_box")
      if (length(get_selected_terms()) == 0) {
        log_warning("invalid range", user_msg = "No terms fall into the selected terms range.")
      } else {
        log_info(
          "generating schedule table",
          user_msg = sprintf(
            "Loading schedule from %s to %s (%d terms )",
            get_selected_terms()[1], tail(get_selected_terms(), 1), length(get_selected_terms())
          )
        )

        shinyjs::show("schedule_box")
      }
    },
    ignoreNULL = FALSE, priority = 100
  )

  # schedule table ======

  schedule <- callModule(
    module_selector_table_server,
    "schedule",
    get_data = get_schedule_for_table,
    id_column = "id",
    # row grouping
    render_html = dplyr::everything(),
    extensions = "RowGroup",
    rowGroup = list(dataSrc = 0),
    columnDefs = list(
      list(visible = FALSE, targets = 0)
    ),
    # view all & scrolling
    allow_view_all = TRUE,
    initial_page_length = -1,
    dom = "ft",
    ordering = FALSE,
    scrollX = TRUE,
    scrollY = "calc(100vh - 260px)", # account for size of header with the -x px
    # don't escape (since we made the columns safe and replaced \n with <br>)
    escape = FALSE,
    selection = list(mode = "single", target = "cell")
  )

  # formatting the schedule for easy visibility
  observeEvent(get_reasons(), {
    log_debug(ns = ns, "update formatting with reasons")
    schedule$change_formatting_calls(
      list(
        list(
          func = DT::formatStyle,
          columns_expr = expr(dplyr::matches(get_term_regexp())),
          backgroundColor = DT::styleEqual(
            levels = c("?", "no", "canceled", get_reasons()),
            values = c("lightgray", "lightpink", "lightpink", rep("lightyellow", length(get_reasons()))),
            default = "lightgreen"
          )
        )
      )
    )
  }, priority = 99)

}


# load UI dynamically
module_schedule_sidebar <- function(id) {
  ns <- NS(id)
  uiOutput(ns("sidebar"))
}

module_schedule_ui <- function(id) {
  ns <- NS(id)
  uiOutput(ns("main")) |> shinycssloaders::withSpinner()
}
