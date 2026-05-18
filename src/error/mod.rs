use color_eyre::{
    config::{HookBuilder, Theme},
    owo_colors::Style,
};

fn theme() -> Theme {
    Theme::dark()
        .help_info_suggestion(Style::new().bright_blue())
        .help_info_note(Style::new().bright_green())
        .help_info_warning(Style::new().bright_yellow())
}

// handler
// {red}error{red}: message
//
// {blue}suggestion{/}: message
//
// {green}note{/}: message
//
// IF not expected
// Please report the issue at: URL
//
// IF backtrace enabled
// backtrace-colored
pub fn install_hooks() -> eyre::Result<()> {
    HookBuilder::new().theme(theme()).install()
}
