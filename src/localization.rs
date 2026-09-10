pub mod bundles {
    use fluent_bundle::{FluentResource, concurrent::FluentBundle};
    use fluent_datetime::BundleExt;
    use std::sync::LazyLock;
    use std::sync::OnceLock;
    use unic_langid::langid;

    use super::functions::*;

    type Bundle = FluentBundle<FluentResource>;

    macro_rules! bundle {
        ($var:ident = $id:literal) => {
            pub static $var: LazyLock<Bundle> = LazyLock::new(|| {
                let mut bundle = Bundle::new_concurrent(vec![langid!($id)]);
                bundle.add_builtins().unwrap();
                bundle.add_datetime_support().unwrap();
                bundle.add_function("STYLE", style).unwrap();
                bundle.add_function("IS_MINIMAL", is_minimal).unwrap();
                bundle.add_function("OPT", opt).unwrap();
                // .ftl files are checked at compile time in `build.rs`
                let resource = FluentResource::try_new(
                    include_str!(concat!("../localization/", $id, "/messages.ftl")).into(),
                )
                .unwrap();
                match bundle.add_resource(resource) {
                    Ok(()) => (),
                    Err(errs) => {
                        for err in errs {
                            eprintln!("ftl error: {err}");
                        }
                        panic!("Failed to add {} locale", $id);
                    }
                }
                bundle
            });
        };
    }

    bundle!(EN_US = "en-US");
    #[cfg(feature = "locale.de-DE")]
    bundle!(DE_DE = "de-DE");
    #[cfg(feature = "locale.fi")]
    bundle!(FI = "fi");
    #[cfg(feature = "locale.fr")]
    bundle!(FR = "fr");
    #[cfg(feature = "locale.it")]
    bundle!(IT = "it");
    #[cfg(feature = "locale.pl")]
    bundle!(PL = "pl");
    #[cfg(feature = "locale.ru")]
    bundle!(RU = "ru");
    #[cfg(feature = "locale.tok")]
    bundle!(TOK = "tok");
    #[cfg(feature = "locale.zh-Hans")]
    bundle!(ZH_HANS = "zh-Hans");

    pub fn locale() -> &'static [&'static LazyLock<Bundle>] {
        LOCALE.get_or_init(init_from_env)
    }

    /// Normalize a POSIX locale string (e.g. `de_DE.UTF-8`, `de-DE@euro`) into
    /// a BCP 47 language identifier that [`unic_langid`] can parse.
    ///
    /// Strips the codeset (`.UTF-8`) and modifier (`@euro`) suffixes that are
    /// part of POSIX locale syntax but not valid in BCP 47, and converts the
    /// underscore separator between language and script/territory to a hyphen.
    fn normalize_posix_locale(raw: &str) -> String {
        let s = raw.trim();
        // Strip codeset (`.UTF-8`) and modifier (`@euro`) suffixes.
        let before_at = s.split('@').next().unwrap_or(s);
        let before_dot = before_at.split('.').next().unwrap_or(before_at);
        // Convert underscore to hyphen (POSIX uses `de_DE`, BCP 47 uses `de-DE`).
        before_dot.replace('_', "-")
    }

    pub fn init_from_env() -> &'static [&'static LazyLock<Bundle>] {
        use std::io::IsTerminal;
        let is_tty = std::io::stdout().is_terminal();
        if is_tty {
            let raw = std::env::var("LC_MESSAGES")
                .or_else(|_| std::env::var("LANG"))
                .unwrap_or_default();
            let normalized = normalize_posix_locale(&raw);
            let lang = normalized
                .parse()
                .unwrap_or_else(|_| langid!("en-US"));
            init_to(&lang)
        } else {
            init_to(&langid!("en-US"))
        }
    }

    pub fn init_to(lang: &unic_langid::LanguageIdentifier) -> &'static [&'static LazyLock<Bundle>] {
        match lang.language.as_str() {
            "en" => const { &[&EN_US] },
            #[cfg(feature = "locale.de-DE")]
            "de" => const { &[&DE_DE, &EN_US] },
            #[cfg(feature = "locale.fi")]
            "fi" => const { &[&FI, &EN_US] },
            #[cfg(feature = "locale.fr")]
            "fr" => const { &[&FR, &EN_US] },
            #[cfg(feature = "locale.it")]
            "it" => const { &[&IT, &EN_US] },
            #[cfg(feature = "locale.pl")]
            "pl" => const { &[&PL, &EN_US] },
            #[cfg(feature = "locale.ru")]
            "ru" => const { &[&RU, &EN_US] },
            #[cfg(feature = "locale.tok")]
            "tok" => const { &[&TOK, &EN_US] },
            // match on lang.script here once more scripts are added
            #[cfg(feature = "locale.zh-Hans")]
            "zh" => const { &[&ZH_HANS, &EN_US] },
            _ => const { &[&EN_US] },
        }
    }

    pub static LOCALE: OnceLock<&[&LazyLock<Bundle>]> = OnceLock::new();

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn test_normalize_posix_locale_strips_codeset() {
            assert_eq!(normalize_posix_locale("de_DE.UTF-8"), "de-DE");
            assert_eq!(normalize_posix_locale("de-DE.UTF-8"), "de-DE");
            assert_eq!(normalize_posix_locale("de_DE.utf8"), "de-DE");
        }

        #[test]
        fn test_normalize_posix_locale_strips_modifier() {
            assert_eq!(normalize_posix_locale("de_DE@euro"), "de-DE");
            assert_eq!(normalize_posix_locale("de-DE@euro"), "de-DE");
        }

        #[test]
        fn test_normalize_posix_locale_strips_both() {
            assert_eq!(normalize_posix_locale("de_DE.UTF-8@euro"), "de-DE");
            assert_eq!(normalize_posix_locale("zh_CN.UTF-8"), "zh-CN");
            assert_eq!(normalize_posix_locale("en_US.UTF-8"), "en-US");
        }

        #[test]
        fn test_normalize_posix_locale_bare_lang() {
            assert_eq!(normalize_posix_locale("de"), "de");
            assert_eq!(normalize_posix_locale("de_DE"), "de-DE");
            assert_eq!(normalize_posix_locale("en-US"), "en-US");
        }

        #[test]
        fn test_normalize_posix_locale_empty() {
            assert_eq!(normalize_posix_locale(""), "");
            assert_eq!(normalize_posix_locale("  "), "");
        }

        #[test]
        fn test_normalize_posix_locale_c_posix() {
            // `C` is a valid POSIX locale but too short to be a BCP 47
            // language subtag (min 2 chars), so it fails parsing and falls
            // through to en-US via `init_from_env`.
            let c_norm = normalize_posix_locale("C");
            assert!(c_norm.parse::<unic_langid::LanguageIdentifier>().is_err());
            // `POSIX` is also a POSIX locale; it may parse as a 6-char language
            // subtag depending on the unic-langid version, but it will not
            // match any known language in `init_to()`, so it still falls back
            // to en-US.
            let posix_norm = normalize_posix_locale("POSIX");
            // We only care that it doesn't match a real locale; verify the
            // normalized form does not start with a known language code.
            assert!(!["en", "de", "fi", "fr", "it", "pl", "ru", "tok", "zh"]
                .contains(&posix_norm.as_str()));
        }
    }
}

mod functions {
    use super::AsFluent;
    use fluent_bundle::{FluentArgs, FluentValue};

    pub fn style<'a>(positional: &[FluentValue<'a>], _: &FluentArgs<'_>) -> FluentValue<'a> {
        let special = crate::special_render();
        let mut out = String::new();
        for arg in positional {
            let FluentValue::String(style) = arg else {
                return FluentValue::Error;
            };
            let ansi = match style.as_ref() {
                "red" => special.red,
                "bright-red" => special.bright_red,
                "green" => special.green,
                "bright-green" => special.bright_green,
                "blue" => special.blue,
                "bright-blue" => special.bright_blue,
                "cyan" => special.cyan,
                "bright-cyan" => special.bright_cyan,
                "yellow" => special.yellow,
                "bright-yellow" => special.bright_yellow,
                "magenta" => special.magenta,
                "bright-magenta" => special.bright_magenta,
                "black" => special.black,
                "dark-grey" | "dark-gray" => special.dark_grey,
                "dark-grey-bg" | "dark-gray-bg" => special.dark_grey_bg,
                "light-grey" | "light-gray" => special.light_grey,
                "white" => special.white,
                "no_fg" => special.no_fg,
                "no_bg" => special.no_bg,
                "reset" => special.reset,

                "italic" => special.italic,
                "bold" => special.bold,
                "strike" => special.strike,
                "no-italic-bold" => special.no_italic_bold,
                "no-strike" => special.no_strike,
                _ => return FluentValue::Error,
            };
            out.push_str(ansi);
        }
        out.into()
    }

    pub fn is_minimal<'a>(_: &[FluentValue<'a>], _: &FluentArgs<'_>) -> FluentValue<'a> {
        crate::special_render().fancy.ftl().into()
    }

    pub fn opt<'a>(positional: &[FluentValue<'a>], _: &FluentArgs<'_>) -> FluentValue<'a> {
        let [value] = positional else {
            return FluentValue::Error;
        };
        match value {
            FluentValue::None => FluentValue::String("none".into()),
            FluentValue::Error => FluentValue::Error,
            _ => FluentValue::String("some".into()),
        }
    }
}

pub trait AsFluent {
    type FluentType;
    fn ftl(self) -> Self::FluentType;
}

impl AsFluent for time::OffsetDateTime {
    type FluentType = fluent_datetime::FluentDateTime;

    fn ftl(self) -> Self::FluentType {
        let date = icu_calendar::Date::try_new_iso(self.year(), self.month() as u8, self.day())
            // icu_calendar::Date and time::Date share the same range restraints, so this can't panic
            .expect("failed invariant");
        let time = icu_time::Time::new(
            self.hour().try_into().expect("same as above"),
            self.minute().try_into().expect("same as above"),
            self.second().try_into().expect("same as above"),
            self.nanosecond().try_into().expect("same as above"),
        );
        fluent_datetime::FluentDateTime::from(icu_time::DateTime { date, time })
    }
}

impl AsFluent for bool {
    type FluentType = &'static str;

    fn ftl(self) -> Self::FluentType {
        if self { "yes" } else { "no" }
    }
}

#[macro_export]
macro_rules! ftl_arg {
    ($args:ident, $var_name:ident) => {
        $args.set(
            stringify!($var_name),
            fluent_bundle::FluentValue::from($var_name),
        );
    };
    ($args:ident, $var_name:ident, $var_value:expr) => {
        $args.set(
            stringify!($var_name),
            fluent_bundle::FluentValue::from($var_value),
        );
    };
}

#[macro_export]
macro_rules! ftl_args {
    () => {
        {
            fluent_bundle::FluentArgs::new()
        }
    };
    ($($var_name:ident $(= $var_val:expr)?),*) => {
        {
            let mut args = fluent_bundle::FluentArgs::new();
            $(
                $crate::ftl_arg!(args, $var_name$(, $var_val)*);
            )*
            args
        }
    };
}

#[macro_export]
macro_rules! ftl_message {
    ($msg_id:expr) => {{
        $crate::localization::bundles::locale()
            .into_iter()
            .find_map(|b| Some((b, b.get_message($msg_id)?)))
    }};
}

#[macro_export]
macro_rules! ftl_pattern {
    ($msg_id:expr) => {{ $crate::ftl_message!($msg_id).and_then(|(b, m)| Some((b, m.value()?))) }};
}

#[macro_export]
macro_rules! ftl_format {
    ($msg_id:expr) => {
        $crate::ftl_format!($msg_id,)
    };
    ($msg_id:expr, $($var_name:ident $(= $var_val:expr)?),* $(,)?) => {
        {
            if let Some((bundle, pattern)) = $crate::ftl_pattern!($msg_id) {
                let args = $crate::ftl_args!($($var_name $(= $var_val)*),*);
                $crate::localization::format_pattern(&***bundle, pattern, Some(&args))
            } else {
                std::borrow::Cow::from($msg_id)
            }

        }
    }
}

#[track_caller]
pub fn handle_pattern_errors(errors: Vec<fluent_bundle::FluentError>) {
    if !errors.is_empty() {
        for error in errors {
            eprintln!("{error}");
        }
        panic!("failed to format localized text");
    }
}

#[track_caller]
pub fn format_pattern<'b>(
    bundle: &'b fluent_bundle::concurrent::FluentBundle<fluent_bundle::FluentResource>,
    pattern: &'b fluent_syntax::ast::Pattern<&'static str>,
    args: Option<&fluent_bundle::FluentArgs<'_>>,
) -> std::borrow::Cow<'b, str> {
    let mut errors = Vec::new();
    let out = bundle.format_pattern(pattern, args, &mut errors);
    handle_pattern_errors(errors);
    out
}

#[macro_export]
macro_rules! ftl_write {
    ($writer:expr, $msg_id:expr) => {
        $crate::ftl_write!($writer, $msg_id,)
    };
    ($writer:expr, $msg_id:expr, $($var_name:ident $(= $var_val:expr)?),* $(,)?) => {
        {
            #[allow(unused)]
            use std::fmt::Write;
            if let Some((bundle, pattern)) = $crate::ftl_pattern!($msg_id) {
                let args = $crate::ftl_args!($($var_name $(= $var_val)*),*);
                $crate::localization::write_pattern($writer, bundle, pattern, Some(&args));
            } else {
                write!($writer, "{}", $msg_id).expect("failed to write text message id");
            }
        }
    }
}

#[track_caller]
pub fn write_pattern<'b>(
    writer: &mut impl std::fmt::Write,
    bundle: &'b fluent_bundle::concurrent::FluentBundle<fluent_bundle::FluentResource>,
    pattern: &'b fluent_syntax::ast::Pattern<&'static str>,
    args: Option<&fluent_bundle::FluentArgs<'_>>,
) {
    let mut errors = Vec::new();
    bundle
        .write_pattern(writer, pattern, args, &mut errors)
        .expect("failed to write localized text");
    handle_pattern_errors(errors);
}

pub struct WriterCompat<W>(pub W);

impl<W: std::io::Write> std::fmt::Write for WriterCompat<W> {
    fn write_str(&mut self, s: &str) -> std::fmt::Result {
        self.0.write_all(s.as_bytes()).map_err(|_| std::fmt::Error)
    }

    fn write_fmt(&mut self, args: std::fmt::Arguments<'_>) -> std::fmt::Result {
        self.0.write_fmt(args).map_err(|_| std::fmt::Error)
    }
}

#[macro_export]
macro_rules! ftl_print {
    ($msg_id:expr) => {
        $crate::ftl_print!($msg_id,)
    };
    ($msg_id:expr, $($var_name:ident $(= $var_val:expr)?),* $(,)?) => {
        {
            let mut stdout = $crate::localization::WriterCompat(std::io::stdout());
            $crate::ftl_write!(&mut stdout, $msg_id, $($var_name $(= $var_val)*),*);
        }
    }
}

#[macro_export]
macro_rules! ftl_println {
    ($msg_id:expr) => {
        $crate::ftl_println!($msg_id,)
    };
    ($msg_id:expr, $($var_name:ident $(= $var_val:expr)?),* $(,)?) => {
        {
            use std::fmt::Write;
            let mut stdout = $crate::localization::WriterCompat(std::io::stdout());
            $crate::ftl_write!(&mut stdout, $msg_id, $($var_name $(= $var_val)*),*);
            writeln!(&mut stdout).expect("failed to write newline");
        }
    }
}

#[macro_export]
macro_rules! ftl_eprint {
    ($msg_id:expr) => {
        $crate::ftl_eprint!($msg_id,)
    };
    ($msg_id:expr, $($var_name:ident $(= $var_val:expr)?),* $(,)?) => {
        {
            let mut stderr = $crate::localization::WriterCompat(std::io::stderr());
            $crate::ftl_write!(&mut stderr, $msg_id, $($var_name $(= $var_val)*),*);
        }
    }
}

#[macro_export]
macro_rules! ftl_eprintln {
    ($msg_id:expr) => {
        $crate::ftl_eprintln!($msg_id,)
    };
    ($msg_id:expr, $($var_name:ident $(= $var_val:expr)?),* $(,)?) => {
        {
            use std::fmt::Write;
            let mut stderr = $crate::localization::WriterCompat(std::io::stderr());
            $crate::ftl_write!(&mut stderr, $msg_id, $($var_name $(= $var_val)*),*);
            writeln!(&mut stderr).expect("failed to write newline");
        }
    }
}

#[macro_export]
macro_rules! ftl_eyre {
    ($msg_id:expr) => {
        $crate::ftl_eyre!($msg_id,)
    };
    ($msg_id:expr, $($var_name:ident $(= $var_val:expr)?),* $(,)?) => {
        {
            eyre::eyre!("{}", $crate::ftl_format!($msg_id, $($var_name $(= $var_val)*),*))
        }
    }
}

#[macro_export]
macro_rules! ftl_bail {
    ($msg_id:expr) => {
        $crate::ftl_bail!($msg_id,)
    };
    ($msg_id:expr, $($var_name:ident $(= $var_val:expr)?),* $(,)?) => {
        {
            eyre::bail!("{}", $crate::ftl_format!($msg_id, $($var_name $(= $var_val)*),*))
        }
    }
}

#[macro_export]
macro_rules! ftl_ensure {
    ($cond:expr, $msg_id:expr) => {
        $crate::ftl_ensure!($cond, $msg_id,)
    };
    ($cond:expr, $msg_id:expr, $($var_name:ident $(= $var_val:expr)?),* $(,)?) => {
        {
            eyre::ensure!($cond, "{}", $crate::ftl_format!($msg_id, $($var_name $(= $var_val)*),*))
        }
    }
}

#[macro_export]
macro_rules! ftl_readline {
    ($msg_id:expr) => {
        $crate::ftl_readline!($msg_id,)
    };
    ($msg_id:expr, $($var_name:ident $(= $var_val:expr)?),* $(,)?) => {
        {
            use std::io::Write;
            $crate::ftl_print!($msg_id, $($var_name $(= $var_val)*),*);
            std::io::stdout().flush().expect("failed to flush stdout");
            $crate::readline()
        }
    }
}

#[macro_export]
macro_rules! ftl_prompt {
    ($msg_id:expr) => {
        $crate::ftl_prompt!($msg_id,)
    };
    ($msg_id:expr, $($var_name:ident $(= $var_val:expr)?),* $(,)?) => {
        {
            $crate::prompt($msg_id, &$crate::ftl_args!($($var_name $(= $var_val)*),*)).await
        }
    }
}

#[macro_export]
macro_rules! ftl_prompt_bool {
    (default $default:expr; $msg_id:expr) => {
        $crate::ftl_prompt_bool!(default $default; $msg_id,)
    };
    (default $default:expr; $msg_id:expr, $($var_name:ident $(= $var_val:expr)?),* $(,)?) => {
        {
            $crate::ftl_prompt!($msg_id, $($var_name $(= $var_val)*),*).map(|o| o.map(|r| r == "yes").unwrap_or($default))
        }
    }
}

/// Helper macros for localizing clap's `help` and `long_help` properties
#[macro_export]
macro_rules! h {
    ($id:literal) => {
        $crate::ftl_format!(concat!("help-", $id))
    };
}
#[macro_export]
macro_rules! lh {
    ($id:literal) => {
        $crate::ftl_format!(concat!("help-", $id, "-long"))
    };
}
