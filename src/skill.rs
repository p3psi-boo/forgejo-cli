use std::io::Write;
use std::path::{Path, PathBuf};

use clap::{Args, Subcommand};
use eyre::Context;

use crate::{ftl_println, h};

pub const SKILL_MARKDOWN: &str = include_str!("../skill/fj/SKILL.md");

#[derive(Args, Clone, Debug)]
pub struct SkillCommand {
    #[clap(subcommand)]
    command: Option<SkillSubcommand>,
}

#[derive(Subcommand, Clone, Debug)]
pub enum SkillSubcommand {
    #[clap(about = h!("cmd-skill-write"))]
    Write {
        #[clap(help = h!("arg-skill-write-path"))]
        #[clap(long, short)]
        path: Option<PathBuf>,
    },
}

impl SkillCommand {
    pub async fn run(self) -> eyre::Result<()> {
        match self.command {
            None => {
                let mut stdout = std::io::stdout();
                stdout.write_all(SKILL_MARKDOWN.as_bytes())?;
                if !SKILL_MARKDOWN.ends_with('\n') {
                    stdout.write_all(b"\n")?;
                }
                stdout.flush()?;
                Ok(())
            }
            Some(SkillSubcommand::Write { path }) => write_skill(path).await,
        }
    }
}

fn default_skill_path() -> PathBuf {
    PathBuf::from(".cursor/skills/fj/SKILL.md")
}

async fn write_skill(path: Option<PathBuf>) -> eyre::Result<()> {
    let path = path.unwrap_or_else(default_skill_path);
    if let Some(parent) = path.parent()
        && !parent.as_os_str().is_empty()
    {
        tokio::fs::create_dir_all(parent)
            .await
            .with_context(|| format!("failed to create {}", parent.display()))?;
    }
    tokio::fs::write(&path, SKILL_MARKDOWN)
        .await
        .with_context(|| format!("failed to write {}", path.display()))?;
    ftl_println!("msg-skill-write-success", path = display_path(&path));
    Ok(())
}

fn display_path(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::Parser;

    #[test]
    fn embedded_skill_has_agent_frontmatter() {
        assert!(
            SKILL_MARKDOWN.starts_with("---\n"),
            "skill must start with YAML frontmatter"
        );
        assert!(
            SKILL_MARKDOWN.contains("name: fj\n"),
            "skill frontmatter must set name: fj"
        );
        assert!(
            SKILL_MARKDOWN.contains("description:"),
            "skill frontmatter must include a description"
        );
        assert!(
            SKILL_MARKDOWN.contains("fj actions view"),
            "skill should document actions view"
        );
        assert!(
            SKILL_MARKDOWN.contains("fj skill write"),
            "skill should document installing itself"
        );
    }

    #[test]
    fn clap_accepts_skill_and_write() {
        crate::App::try_parse_from(["fj", "skill"]).unwrap();
        crate::App::try_parse_from(["fj", "skill", "write"]).unwrap();
        crate::App::try_parse_from(["fj", "skill", "write", "--path", "out/SKILL.md"]).unwrap();
    }
}
