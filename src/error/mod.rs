use std::backtrace::{Backtrace, BacktraceStatus};

use eyre::EyreHandler;

pub fn install_hooks() -> eyre::Result<()> {
    // Keep color-eyre's panic hook (rich panic output), but discard its eyre
    // hook in favour of our own `Handler` below.
    let (panic_hook, _) = color_eyre::config::HookBuilder::new().into_hooks();
    std::panic::set_hook(Box::new(panic_hook.into_panic_hook()));

    // `Handler::new` runs when each `eyre::Report` is created, so the backtrace
    // is captured at the point the error originates.
    eyre::set_hook(Box::new(|_| Box::new(Handler::new())))?;
    Ok(())
}

/// Renders every [`eyre::Report`] in one consistent, colored layout. Sections
/// are written in this order, blank-line separated, each shown only when it has
/// content (colors come from [`crate::special_render`], so `--style minimal`
/// and non-terminal output drop the escape codes):
///
/// ```text
/// error: <message>                          bright red + bold
/// caused by: <source>                       cyan, one per cause in the chain
/// suggestion: <text>                        green, one per `.suggestion(..)`
/// Please report the issue at: <repo>/issues only when not `.expected()`
/// Stack backtrace:                          faint, only when RUST_BACKTRACE is set
/// ```
///
/// Use [`Section`] to attach suggestions and mark user errors as expected.
#[derive(Debug)]
struct Handler {
    suggestions: Vec<String>,
    /// `true` = user mistake: show suggestions, hide the "please report" line.
    /// `false` = internal/unexpected error (the default).
    expected: bool,
    backtrace: Backtrace,
}

impl Handler {
    fn new() -> Self {
        // `Backtrace::capture` already respects `RUST_BACKTRACE`/`RUST_LIB_BACKTRACE`.
        let backtrace = Backtrace::capture();
        Self {
            suggestions: Vec::new(),
            expected: false,
            backtrace,
        }
    }
}

impl EyreHandler for Handler {
    fn debug(
        &self,
        error: &(dyn std::error::Error + 'static),
        f: &mut core::fmt::Formatter<'_>,
    ) -> core::fmt::Result {
        let r = crate::special_render();

        // {red}error{red}: message
        write!(f, "{}{}error{}: {error}", r.bright_red, r.bold, r.reset)?;

        // caused by: ... (dimmed cause chain)
        let mut source = error.source();
        while let Some(cause) = source {
            write!(f, "\n\n{}caused by{}: {cause}", r.cyan, r.reset)?;
            source = cause.source();
        }

        // {green}suggestion{/}: message
        for suggestion in &self.suggestions {
            write!(f, "\n\n{}suggestion{}: {suggestion}", r.green, r.reset)?;
        }

        // IF not expected: Please report the issue at: URL
        if !self.expected {
            write!(
                f,
                "\n\nPlease report the issue at: {}/issues",
                env!("CARGO_PKG_REPOSITORY").trim_end_matches('/'),
            )?;
        }

        // IF backtrace enabled: backtrace-colored
        if self.backtrace.status() == BacktraceStatus::Captured {
            write!(
                f,
                "\n\nStack backtrace:\n{}{}{}",
                r.faint, self.backtrace, r.reset
            )?;
        }

        Ok(())
    }
}

/// Attach guidance to an `eyre::Report`/`Result`, and classify it as a user
/// mistake (`expected`) rather than an internal bug.
///
/// ```ignore
/// some_fn()
///     .suggestion("run `fj auth login` first")
///     .expected()?;
/// ```
pub trait Section: Sized {
    fn suggestion(self, suggestion: impl Into<String>) -> Self;
    /// Mark this error as a user mistake: suppresses the "Please report" line.
    fn expected(self) -> Self;
}

impl Section for eyre::Report {
    fn suggestion(mut self, suggestion: impl Into<String>) -> Self {
        if let Some(handler) = self.handler_mut().downcast_mut::<Handler>() {
            handler.suggestions.push(suggestion.into());
        }
        self
    }

    fn expected(mut self) -> Self {
        if let Some(handler) = self.handler_mut().downcast_mut::<Handler>() {
            handler.expected = true;
        }
        self
    }
}

impl<T> Section for eyre::Result<T> {
    fn suggestion(self, suggestion: impl Into<String>) -> Self {
        self.map_err(|report| report.suggestion(suggestion))
    }

    fn expected(self) -> Self {
        self.map_err(|report| report.expected())
    }
}
