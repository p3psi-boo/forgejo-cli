use clap::{Args, Subcommand};
use eyre::{Context, OptionExt, bail, eyre};
use forgejo_api::{
    Forgejo,
    structs::{RepoCreateReleaseAttachmentQuery, RepoListReleasesQuery},
};
use futures::stream::TryStreamExt;
use tokio::io::AsyncWriteExt;

use crate::{
    SpecialRender, ftl_bail, ftl_println, h,
    keys::KeyInfo,
    lh,
    localization::AsFluent,
    repo::{RepoArg, RepoInfo, RepoName},
};

#[derive(Args, Clone, Debug)]
pub struct ReleaseCommand {
    #[clap(long, short = 'R', global = true)]
    remote: Option<String>,
    #[clap(long, short, global = true)]
    repo: Option<RepoArg>,
    #[clap(subcommand)]
    command: ReleaseSubcommand,
}

#[derive(Subcommand, Clone, Debug)]
pub enum ReleaseSubcommand {
    #[clap(about = h!("cmd-release-create"))]
    Create {
        name: String,
        #[clap(help = h!("arg-release-create-create_tag"))]
        #[clap(long, short = 'T')]
        create_tag: Option<Option<String>>,

        #[clap(help = h!("arg-release-create-tag"), long_help = lh!("arg-release-create-tag"))]
        #[clap(long, short = 't')]
        tag: Option<String>,

        #[clap(help = h!("arg-release-create-attach"), long_help = lh!("arg-release-create-attach"))]
        #[clap(long, short)]
        attach: Vec<String>,

        #[clap(help = h!("arg-release-create-body"), long_help = lh!("arg-release-create-body"))]
        #[clap(long, short)]
        body: Option<Option<String>>,

        #[clap(long, short = 'B')]
        branch: Option<String>,

        #[clap(long, short)]
        draft: bool,

        #[clap(long, short)]
        prerelease: bool,
    },
    #[clap(about = h!("cmd-release-edit"))]
    Edit {
        name: String,

        #[clap(long, short = 'n')]
        rename: Option<String>,

        #[clap(help = h!("arg-release-edit-tag"))]
        #[clap(long, short = 't')]
        tag: Option<String>,

        #[clap(help = h!("arg-release-edit-body"), long_help = lh!("arg-release-edit-body"))]
        #[clap(long, short)]
        body: Option<Option<String>>,

        #[clap(long, short)]
        draft: Option<bool>,

        #[clap(long, short)]
        prerelease: Option<bool>,
    },
    #[clap(about = h!("cmd-release-delete"))]
    Delete {
        name: String,
        #[clap(long, short = 't')]
        by_tag: bool,
    },
    #[clap(about = h!("cmd-release-list"))]
    List {
        #[clap(long, short = 'p')]
        include_prerelease: bool,
        #[clap(long, short = 'd')]
        include_draft: bool,
    },
    #[clap(about = h!("cmd-release-view"))]
    View {
        name: String,
        #[clap(long, short = 't')]
        by_tag: bool,
    },
    #[clap(about = h!("cmd-release-browse"))]
    Browse { name: Option<String> },
    #[clap(about = h!("cmd-release-asset"))]
    #[clap(subcommand)]
    Asset(AssetCommand),
}

#[derive(Subcommand, Clone, Debug)]
pub enum AssetCommand {
    #[clap(about = h!("cmd-release-asset-create"))]
    Create {
        release: String,
        path: std::path::PathBuf,
        name: Option<String>,
    },
    #[clap(about = h!("cmd-release-asset-delete"))]
    Delete { release: String, asset: String },
    #[clap(about = h!("cmd-release-asset-download"))]
    Download {
        release: String,
        asset: String,
        #[clap(long, short)]
        output: Option<std::path::PathBuf>,
    },
}

impl ReleaseCommand {
    pub async fn run(self, keys: &mut KeyInfo, remote_name: Option<&str>) -> eyre::Result<()> {
        let repo = RepoInfo::get_current(
            remote_name,
            self.repo.as_ref(),
            self.remote.as_deref(),
            keys,
        )?;
        let api = keys.get_api(repo.host_url()).await?;
        let repo = repo
            .name()
            .ok_or_eyre("couldn't get repo name, try specifying with --repo")?;
        match self.command {
            ReleaseSubcommand::Create {
                name,
                create_tag,
                tag,
                attach,
                body,
                branch,
                draft,
                prerelease,
            } => {
                create_release(
                    repo, &api, name, create_tag, tag, attach, body, branch, draft, prerelease,
                )
                .await?
            }
            ReleaseSubcommand::Edit {
                name,
                rename,
                tag,
                body,
                draft,
                prerelease,
            } => edit_release(repo, &api, name, rename, tag, body, draft, prerelease).await?,
            ReleaseSubcommand::Delete { name, by_tag } => {
                delete_release(repo, &api, name, by_tag).await?
            }
            ReleaseSubcommand::List {
                include_prerelease,
                include_draft,
            } => list_releases(repo, &api, include_prerelease, include_draft).await?,
            ReleaseSubcommand::View { name, by_tag } => {
                view_release(repo, &api, name, by_tag).await?
            }
            ReleaseSubcommand::Browse { name } => browse_release(repo, &api, name).await?,
            ReleaseSubcommand::Asset(subcommand) => match subcommand {
                AssetCommand::Create {
                    release,
                    path,
                    name,
                } => create_asset(repo, &api, release, path, name).await?,
                AssetCommand::Delete { release, asset } => {
                    delete_asset(repo, &api, release, asset).await?
                }
                AssetCommand::Download {
                    release,
                    asset,
                    output,
                } => download_asset(repo, &api, release, asset, output).await?,
            },
        }
        Ok(())
    }
}

#[allow(clippy::too_many_arguments)]
async fn create_release(
    repo: &RepoName,
    api: &Forgejo,
    name: String,
    create_tag: Option<Option<String>>,
    tag: Option<String>,
    attachments: Vec<String>,
    body: Option<Option<String>>,
    branch: Option<String>,
    draft: bool,
    prerelease: bool,
) -> eyre::Result<()> {
    let tag_name = match (tag, create_tag) {
        (None, None) => ftl_bail!("msg-release-create-must_specify_tag"),
        (Some(tag), None) => tag,
        (None, Some(tag)) => {
            let tag = tag.unwrap_or_else(|| name.clone());
            let opt = forgejo_api::structs::CreateTagOption {
                message: None,
                tag_name: tag.clone(),
                target: branch,
            };
            api.repo_create_tag(repo.owner(), repo.name(), opt).await?;
            tag
        }
        (Some(_), Some(_)) => {
            ftl_bail!("msg-release-create-tag_flags_conflict")
        }
    };

    let body = match body {
        Some(Some(body)) => Some(body),
        Some(None) => {
            let mut s = String::new();
            crate::editor(&mut s, Some("md")).await?;
            Some(s)
        }
        None => None,
    };

    let release_opt = forgejo_api::structs::CreateReleaseOption {
        hide_archive_links: None,
        body,
        draft: Some(draft),
        name: Some(name.clone()),
        prerelease: Some(prerelease),
        tag_name,
        target_commitish: None,
    };
    let release = api
        .repo_create_release(repo.owner(), repo.name(), release_opt)
        .await?;

    for attachment in attachments {
        let (file, asset) = match attachment.split_once(':') {
            Some((file, asset)) => (std::path::Path::new(file), asset),
            None => {
                let file = std::path::Path::new(&attachment);
                let asset = file
                    .file_name()
                    .ok_or_else(|| eyre!("{attachment} does not have a file name"))?
                    .to_str()
                    .unwrap();
                (file, asset)
            }
        };
        let query = RepoCreateReleaseAttachmentQuery {
            name: Some(asset.into()),
        };
        let id = release
            .id
            .ok_or_else(|| eyre::eyre!("release does not have id"))?;
        api.repo_create_release_attachment(
            repo.owner(),
            repo.name(),
            id,
            Some(&tokio::fs::read(file).await?),
            None,
            query,
        )
        .await?;
    }

    ftl_println!("msg-release-create-success", name);

    Ok(())
}

#[allow(clippy::too_many_arguments)]
async fn edit_release(
    repo: &RepoName,
    api: &Forgejo,
    name: String,
    rename: Option<String>,
    tag: Option<String>,
    body: Option<Option<String>>,
    draft: Option<bool>,
    prerelease: Option<bool>,
) -> eyre::Result<()> {
    let release = find_release(repo, api, &name).await?;
    let body = match body {
        Some(Some(body)) => Some(body),
        Some(None) => {
            let mut s = release
                .body
                .clone()
                .ok_or_else(|| eyre::eyre!("release does not have body"))?;
            crate::editor(&mut s, Some("md")).await?;
            Some(s)
        }
        None => None,
    };
    let release_edit = forgejo_api::structs::EditReleaseOption {
        hide_archive_links: None,
        name: rename,
        tag_name: tag,
        body,
        draft,
        prerelease,
        target_commitish: None,
    };
    let id = release
        .id
        .ok_or_else(|| eyre::eyre!("release does not have id"))?;
    api.repo_edit_release(repo.owner(), repo.name(), id, release_edit)
        .await?;
    Ok(())
}

async fn list_releases(
    repo: &RepoName,
    api: &Forgejo,
    prerelease: bool,
    draft: bool,
) -> eyre::Result<()> {
    let query = forgejo_api::structs::RepoListReleasesQuery {
        q: None,
        pre_release: Some(prerelease),
        draft: Some(draft),
    };
    let (_, releases) = api
        .repo_list_releases(repo.owner(), repo.name(), query)
        .await?;
    for release in releases {
        let name = release
            .name
            .as_ref()
            .ok_or_else(|| eyre::eyre!("release does not have name"))?;
        let draft = release
            .draft
            .as_ref()
            .ok_or_else(|| eyre::eyre!("release does not have draft"))?;
        let prerelease = release
            .prerelease
            .as_ref()
            .ok_or_else(|| eyre::eyre!("release does not have prerelease"))?;
        let state = match (draft, prerelease) {
            (false, false) => "neither",
            (true, false) => "draft",
            (false, true) => "prerelease",
            (true, true) => "both",
        };
        ftl_println!("msg-release-list-entry", name, state);
    }
    Ok(())
}

async fn view_release(
    repo: &RepoName,
    api: &Forgejo,
    name: String,
    by_tag: bool,
) -> eyre::Result<()> {
    let release = if by_tag {
        api.repo_get_release_by_tag(repo.owner(), repo.name(), &name)
            .await?
    } else {
        find_release(repo, api, &name).await?
    };
    let name = release
        .name
        .as_ref()
        .ok_or_else(|| eyre::eyre!("release does not have name"))?;
    let author = release
        .author
        .as_ref()
        .ok_or_else(|| eyre::eyre!("release does not have author"))?;
    let author = author
        .login
        .as_ref()
        .ok_or_else(|| eyre::eyre!("autho does not have login"))?;
    let created_at = release
        .created_at
        .ok_or_else(|| eyre::eyre!("release does not have created_at"))?;
    ftl_println!(
        "msg-release-view-header",
        name,
        author,
        created_at = created_at.ftl(),
    );
    let SpecialRender { bullet, .. } = crate::special_render();
    let body = release
        .body
        .as_ref()
        .ok_or_else(|| eyre::eyre!("release does not have body"))?;
    if !body.is_empty() {
        println!();
        println!("{}", crate::markdown(body));
        println!();
    }
    let assets = release
        .assets
        .as_ref()
        .ok_or_else(|| eyre::eyre!("release does not have assets"))?;
    if !assets.is_empty() {
        println!("{} assets", assets.len() + 2);
        for asset in assets {
            let name = asset
                .name
                .as_ref()
                .ok_or_else(|| eyre::eyre!("asset does not have name"))?;
            println!("{bullet} {}", name);
        }
        println!("{bullet} source.zip");
        println!("{bullet} source.tar.gz");
    }
    Ok(())
}

async fn browse_release(repo: &RepoName, api: &Forgejo, name: Option<String>) -> eyre::Result<()> {
    match name {
        Some(name) => {
            let release = find_release(repo, api, &name).await?;
            let html_url = release
                .html_url
                .as_ref()
                .ok_or_else(|| eyre::eyre!("release does not have html_url"))?;
            open::that_detached(html_url.as_str()).wrap_err("Failed to open URL")?;
        }
        None => {
            let repo_data = api.repo_get(repo.owner(), repo.name()).await?;
            let mut html_url = repo_data
                .html_url
                .clone()
                .ok_or_else(|| eyre::eyre!("repository does not have html_url"))?;
            html_url.path_segments_mut().unwrap().push("releases");
            open::that_detached(html_url.as_str()).wrap_err("Failed to open URL")?;
        }
    }
    Ok(())
}

async fn create_asset(
    repo: &RepoName,
    api: &Forgejo,
    release: String,
    file: std::path::PathBuf,
    asset: Option<String>,
) -> eyre::Result<()> {
    let (file, asset) = match asset {
        Some(ref asset) => (&*file, &**asset),
        None => {
            let asset = file
                .file_name()
                .ok_or_else(|| eyre!("{} does not have a file name", file.display()))?
                .to_str()
                .unwrap();
            (&*file, asset)
        }
    };
    let id = find_release(repo, api, &release)
        .await?
        .id
        .ok_or_else(|| eyre::eyre!("release does not have id"))?;
    let query = RepoCreateReleaseAttachmentQuery {
        name: Some(asset.to_owned()),
    };
    api.repo_create_release_attachment(
        repo.owner(),
        repo.name(),
        id,
        Some(&tokio::fs::read(file).await?),
        None,
        query,
    )
    .await?;

    ftl_println!("msg-release-asset-create-success", asset, release);

    Ok(())
}

async fn delete_asset(
    repo: &RepoName,
    api: &Forgejo,
    release_name: String,
    asset_name: String,
) -> eyre::Result<()> {
    let release = find_release(repo, api, &release_name).await?;
    let assets = release
        .assets
        .as_ref()
        .ok_or_else(|| eyre::eyre!("release does not have assets"))?;
    let asset = assets
        .iter()
        .find(|a| a.name.as_ref() == Some(&asset_name))
        .ok_or_else(|| eyre!("asset not found"))?;
    let release_id = release
        .id
        .ok_or_else(|| eyre::eyre!("release does not have id"))?;
    let asset_id = asset
        .id
        .ok_or_else(|| eyre::eyre!("asset does not have id"))?;
    api.repo_delete_release_attachment(repo.owner(), repo.name(), release_id, asset_id)
        .await?;
    println!("Removed attachment `{}` from {}", asset_name, release_name);
    ftl_println!(
        "msg-release-asset-delete-success",
        asset = asset_name,
        release = release_name,
    );
    Ok(())
}

async fn download_asset(
    repo: &RepoName,
    api: &Forgejo,
    release: String,
    asset: String,
    output: Option<std::path::PathBuf>,
) -> eyre::Result<()> {
    let release = find_release(repo, api, &release).await?;
    let file = match &*asset {
        "source.zip" => {
            let tag_name = release
                .tag_name
                .as_ref()
                .ok_or_else(|| eyre::eyre!("release does not have tag_name"))?;
            api.repo_get_archive(repo.owner(), repo.name(), &format!("{}.zip", tag_name))
                .await?
        }
        "source.tar.gz" => {
            let tag_name = release
                .tag_name
                .as_ref()
                .ok_or_else(|| eyre::eyre!("release does not have tag_name"))?;
            api.repo_get_archive(repo.owner(), repo.name(), &format!("{}.tar.gz", tag_name))
                .await?
        }
        name => {
            let assets = release
                .assets
                .as_ref()
                .ok_or_else(|| eyre::eyre!("release does not have assets"))?;
            let asset = assets
                .iter()
                .find(|a| a.name.as_deref() == Some(name))
                .ok_or_else(|| eyre!("asset not found"))?;
            let release_id = release
                .id
                .ok_or_else(|| eyre::eyre!("release does not have id"))?;
            let asset_id = asset
                .id
                .ok_or_else(|| eyre::eyre!("asset does not have id"))?;
            api.download_release_attachment(repo.owner(), repo.name(), release_id, asset_id)
                .await?
        }
    };
    let real_output = resolve_asset_output_path(&asset, output.as_deref())?;
    tokio::fs::OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(&real_output)
        .await?
        .write_all(file.as_ref())
        .await?;

    ftl_println!(
        "msg-release-asset-download-success",
        asset = &asset,
        file = output.as_deref().map(|p| p.to_string_lossy()),
    );

    Ok(())
}

async fn find_release(
    repo: &RepoName,
    api: &Forgejo,
    name: &str,
) -> eyre::Result<forgejo_api::structs::Release> {
    let query = RepoListReleasesQuery {
        q: None,
        draft: None,
        pre_release: None,
    };
    api.repo_list_releases(repo.owner(), repo.name(), query)
        .stream()
        .try_filter(|r| {
            futures::future::ready(
                r.name
                    .as_deref()
                    .is_some_and(|release_name| release_name == name),
            )
        })
        .try_next()
        .await?
        .ok_or_else(|| eyre::eyre!("could not find release {name}"))
}

async fn delete_release(
    repo: &RepoName,
    api: &Forgejo,
    name: String,
    by_tag: bool,
) -> eyre::Result<()> {
    if by_tag {
        api.repo_delete_release_by_tag(repo.owner(), repo.name(), &name)
            .await?;
    } else {
        let id = find_release(repo, api, &name)
            .await?
            .id
            .ok_or_else(|| eyre::eyre!("release does not have id"))?;
        api.repo_delete_release(repo.owner(), repo.name(), id)
            .await?;
    }
    Ok(())
}

pub(crate) fn safe_asset_filename(asset: &str) -> eyre::Result<std::path::PathBuf> {
    if asset.is_empty() {
        bail!("invalid asset name `{asset}`: asset name cannot be empty");
    }
    if asset.contains('\0') {
        bail!("invalid asset name `{asset}`: contains null byte");
    }

    let sanitized: String = asset
        .chars()
        .map(|c| match c {
            '/' | '\\' | ':' => '_',
            other => other,
        })
        .collect();

    if sanitized == "." || sanitized == ".." {
        bail!("invalid asset name `{asset}`: cannot determine safe file name");
    }

    Ok(std::path::PathBuf::from(sanitized))
}

pub(crate) fn resolve_asset_output_path(
    asset: &str,
    output: Option<&std::path::Path>,
) -> eyre::Result<std::path::PathBuf> {
    match output {
        Some(path) if path.is_dir() => {
            let file_name = safe_asset_filename(asset)?;
            Ok(path.join(file_name))
        }
        Some(path) => Ok(path.to_path_buf()),
        None => safe_asset_filename(asset),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    #[test]
    fn test_safe_asset_filename_normal() {
        assert_eq!(
            safe_asset_filename("release-v1.0.tar.gz").unwrap(),
            Path::new("release-v1.0.tar.gz")
        );
        assert_eq!(
            safe_asset_filename("nested/dir/asset.zip").unwrap(),
            Path::new("nested_dir_asset.zip")
        );
    }

    #[test]
    fn test_safe_asset_filename_injective() {
        let bar_foo = safe_asset_filename("bar/foo").unwrap();
        let baz_foo = safe_asset_filename("baz/foo").unwrap();
        assert_ne!(bar_foo, baz_foo);
        assert_eq!(bar_foo, Path::new("bar_foo"));
        assert_eq!(baz_foo, Path::new("baz_foo"));
    }

    #[test]
    fn test_safe_asset_filename_path_traversal() {
        assert_eq!(
            safe_asset_filename("../../evil.sh").unwrap(),
            Path::new(".._.._evil.sh")
        );
        assert_eq!(
            safe_asset_filename("..\\..\\evil.exe").unwrap(),
            Path::new(".._.._evil.exe")
        );
        assert_eq!(
            safe_asset_filename("/etc/passwd").unwrap(),
            Path::new("_etc_passwd")
        );
    }

    #[test]
    fn test_safe_asset_filename_windows_drive_paths() {
        // Absolute style: C:\foo and C:\path\to\asset.zip
        assert_eq!(safe_asset_filename(r"C:\foo").unwrap(), Path::new("C__foo"));
        assert_eq!(
            safe_asset_filename(r"C:\path\to\asset.zip").unwrap(),
            Path::new("C__path_to_asset.zip")
        );
        // Relative style: C:foo and C:path/to/asset.zip
        assert_eq!(safe_asset_filename("C:foo").unwrap(), Path::new("C_foo"));
        assert_eq!(
            safe_asset_filename("C:path/to/asset.zip").unwrap(),
            Path::new("C_path_to_asset.zip")
        );
    }

    #[test]
    fn test_safe_asset_filename_invalid() {
        assert!(safe_asset_filename("").is_err());
        assert!(safe_asset_filename(".").is_err());
        assert!(safe_asset_filename("..").is_err());
        assert!(safe_asset_filename("payload\0bad").is_err());
    }

    #[test]
    fn test_resolve_asset_output_path() {
        let default_path = resolve_asset_output_path("../../payload.bin", None).unwrap();
        assert_eq!(default_path, Path::new(".._.._payload.bin"));

        let explicit = Path::new("custom/path/out.bin");
        let path = resolve_asset_output_path("payload.bin", Some(explicit)).unwrap();
        assert_eq!(path, explicit);
    }
}
