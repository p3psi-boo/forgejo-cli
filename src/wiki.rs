use std::path::PathBuf;

use base64ct::Encoding;
use clap::{Args, Subcommand};
use eyre::{Context, OptionExt, bail, eyre};
use forgejo_api::Forgejo;

use crate::{
    SpecialRender, ftl_println, h,
    repo::{RepoArg, RepoInfo, RepoName},
};

#[derive(Args, Clone, Debug)]
pub struct WikiCommand {
    #[clap(help = h!("arg-remote"))]
    #[clap(long, short = 'R', global = true)]
    remote: Option<String>,

    #[clap(help = h!("arg-repo"))]
    #[clap(long, short, global = true)]
    repo: Option<RepoArg>,

    #[clap(subcommand)]
    command: WikiSubcommand,
}

#[derive(Subcommand, Clone, Debug)]
pub enum WikiSubcommand {
    Contents,
    View {
        page: String,
    },
    Clone {
        #[clap(long, short)]
        path: Option<PathBuf>,

        #[clap(help = h!("arg-wiki-clone-ssh"))]
        #[clap(long, short = 'S')]
        ssh: Option<Option<bool>>,

        #[clap(help = h!("arg-wiki-clone-identity_file"))]
        #[clap(long, short = 'I')]
        identity_file: Option<PathBuf>,
    },
    Browse {
        page: String,
    },
}

impl WikiCommand {
    pub async fn run(self, keys: &mut crate::KeyInfo, host_name: Option<&str>) -> eyre::Result<()> {
        use WikiSubcommand::*;

        let repo =
            RepoInfo::get_current(host_name, self.repo.as_ref(), self.remote.as_deref(), keys)?;
        let api = keys.get_api(repo.host_url()).await?;
        let repo_name = repo
            .name()
            .ok_or_else(|| eyre::eyre!("couldn't guess repo"))?;

        match self.command {
            Contents => wiki_contents(repo_name, &api).await?,
            View { page } => view_wiki_page(repo_name, &api, &page).await?,
            Clone {
                path,
                ssh,
                identity_file: identity,
            } => {
                let url_host = crate::host_name(repo.host_url());
                let ssh = ssh
                    .unwrap_or_else(|| Some(keys.default_ssh.contains(url_host)))
                    .unwrap_or(true);
                clone_wiki(repo_name, &api, path, ssh, identity).await?;
            }
            Browse { page } => browse_wiki_page(repo_name, &api, &page).await?,
        }
        Ok(())
    }
}

async fn wiki_contents(repo: &RepoName, api: &Forgejo) -> eyre::Result<()> {
    let SpecialRender { bullet, .. } = *crate::special_render();

    let pages = api
        .repo_get_wiki_pages(repo.owner(), repo.name())
        .all()
        .await?;
    for page in pages {
        let title = page
            .title
            .as_deref()
            .ok_or_eyre("page does not have title")?;
        println!("{bullet} {title}");
    }

    Ok(())
}

async fn view_wiki_page(repo: &RepoName, api: &Forgejo, page: &str) -> eyre::Result<()> {
    let SpecialRender { bold, reset, .. } = *crate::special_render();

    let page = api
        .repo_get_wiki_page(repo.owner(), repo.name(), page)
        .await?;

    let title = page
        .title
        .as_deref()
        .ok_or_eyre("page does not have title")?;
    println!("{bold}{title}{reset}");
    println!();

    let contents_b64 = page
        .content_base64
        .as_deref()
        .ok_or_eyre("page does not have content")?;
    let contents = String::from_utf8(base64ct::Base64::decode_vec(contents_b64)?)
        .wrap_err("page content is not utf-8")?;

    println!("{}", crate::markdown(&contents));
    Ok(())
}

async fn browse_wiki_page(repo: &RepoName, api: &Forgejo, page: &str) -> eyre::Result<()> {
    let page = api
        .repo_get_wiki_page(repo.owner(), repo.name(), page)
        .await?;
    let html_url = page
        .html_url
        .as_ref()
        .ok_or_eyre("page does not have html url")?;
    validate_web_url(html_url)?;
    open::that_detached(html_url.as_str()).wrap_err("Failed to open URL")?;
    Ok(())
}

async fn clone_wiki(
    repo: &RepoName,
    api: &Forgejo,
    path: Option<PathBuf>,
    ssh: bool,
    identity_file: Option<PathBuf>,
) -> eyre::Result<()> {
    let repo_data = api.repo_get(repo.owner(), repo.name()).await?;
    let clone_url = if ssh {
        repo_data
            .ssh_url
            .as_ref()
            .ok_or_eyre("repo does not have ssh url")?
    } else {
        repo_data
            .clone_url
            .as_ref()
            .ok_or_eyre("repo does not have clone url")?
    };

    let git_stripped = clone_url
        .as_str()
        .strip_suffix(".git")
        .unwrap_or(clone_url.as_str());
    let clone_url = url::Url::parse(&format!("{}.wiki.git", git_stripped))?;

    let repo_name = repo_data
        .name
        .as_deref()
        .ok_or_eyre("repo does not have name")?;
    let repo_full_name = repo_data
        .full_name
        .as_deref()
        .ok_or_eyre("repo does not have full name")?;

    let path = match path {
        Some(p) => p,
        None => safe_default_clone_dir(repo_name, "-wiki")?,
    };

    crate::repo::clone_repo(&clone_url, &path, identity_file.as_deref())?;
    ftl_println!(
        "msg-wiki-clone-success",
        repo = repo_full_name,
        path = path.display().to_string(),
    );

    Ok(())
}

pub(crate) fn validate_web_url(url: &url::Url) -> eyre::Result<()> {
    match url.scheme() {
        "http" | "https" => Ok(()),
        scheme => {
            bail!("refusing to open unsupported URL scheme `{scheme}`: expected http or https")
        }
    }
}

pub(crate) fn safe_default_clone_dir(repo_name: &str, suffix: &str) -> eyre::Result<PathBuf> {
    let normalized = repo_name.replace('\\', "/");
    let path = std::path::Path::new(&normalized);
    let dir_name = path.file_name().and_then(|f| f.to_str()).ok_or_else(|| {
        eyre!("invalid repository name `{repo_name}`: missing valid directory name")
    })?;
    if dir_name.is_empty() || dir_name == "." || dir_name == ".." {
        return Err(eyre!(
            "invalid repository name `{repo_name}`: cannot determine safe directory name"
        ));
    }
    Ok(PathBuf::from(format!("./{dir_name}{suffix}")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_validate_web_url_valid() {
        let http_url = url::Url::parse("http://codeberg.org/owner/repo/wiki/Home").unwrap();
        assert!(validate_web_url(&http_url).is_ok());

        let https_url = url::Url::parse("https://codeberg.org/owner/repo/wiki/Home").unwrap();
        assert!(validate_web_url(&https_url).is_ok());
    }

    #[test]
    fn test_validate_web_url_invalid_schemes() {
        for invalid in &[
            "file:///etc/passwd",
            "javascript:alert(1)",
            "ssh://git@codeberg.org/repo.git",
            "ftp://files.example.com",
            "data:text/html,hello",
        ] {
            let parsed = url::Url::parse(invalid).unwrap();
            let res = validate_web_url(&parsed);
            assert!(res.is_err(), "expected error for URL: {invalid}");
        }
    }

    #[test]
    fn test_safe_default_clone_dir_normal() {
        let path = safe_default_clone_dir("my-repo", "-wiki").unwrap();
        assert_eq!(path, PathBuf::from("./my-repo-wiki"));
    }

    #[test]
    fn test_safe_default_clone_dir_path_traversal() {
        let path1 = safe_default_clone_dir("../../evil", "-wiki").unwrap();
        assert_eq!(path1, PathBuf::from("./evil-wiki"));

        let path2 = safe_default_clone_dir("..\\..\\windows_evil", "-wiki").unwrap();
        assert_eq!(path2, PathBuf::from("./windows_evil-wiki"));

        let path3 = safe_default_clone_dir("/absolute/path/nested", "-wiki").unwrap();
        assert_eq!(path3, PathBuf::from("./nested-wiki"));
    }

    #[test]
    fn test_safe_default_clone_dir_invalid() {
        assert!(safe_default_clone_dir("", "-wiki").is_err());
        assert!(safe_default_clone_dir(".", "-wiki").is_err());
        assert!(safe_default_clone_dir("..", "-wiki").is_err());
        assert!(safe_default_clone_dir("../..", "-wiki").is_err());
        assert!(safe_default_clone_dir("/", "-wiki").is_err());
    }
}
