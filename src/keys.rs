use forgejo_api::{Auth, Forgejo};
use std::{
    collections::{BTreeMap, BTreeSet},
    io::ErrorKind,
    path::Path,
};
use tokio::io::AsyncWriteExt;
use url::Url;

use crate::{ftl_eyre, ftl_println};

#[derive(serde::Serialize, serde::Deserialize, Clone, Default)]
pub struct KeyInfo {
    pub hosts: BTreeMap<String, LoginInfo>,
    #[serde(default)]
    pub aliases: BTreeMap<String, String>,
    #[serde(default)]
    pub default_ssh: BTreeSet<String>,
}

impl KeyInfo {
    // Try the old path for backwards compatibility
    // Give this a release or two for users to migrate and then remove this codepath
    async fn load_fallback(new_path: &Path) -> eyre::Result<Self> {
        let fallback = directories::ProjectDirs::from("", "Cyborus", "forgejo-cli")
            .ok_or_else(|| ftl_eyre!("msg-project-dir-not-found"))?
            .data_dir()
            .join("keys.json");
        let json = tokio::fs::read(fallback).await;
        let this = match json {
            Ok(x) => {
                ftl_println!("msg-old-key-file-read");
                serde_json::from_slice::<Self>(&x)?
            }
            Err(e) if e.kind() == ErrorKind::NotFound => {
                ftl_println!("msg-key-file-not-found");
                return Ok(Self::default());
            }
            Err(e) => return Err(e.into()),
        };
        if this.save().await.is_err() {
            ftl_println!(
                "msg-save-migrated-key-file-fail",
                path = new_path.to_string_lossy()
            );
        }
        Ok(this)
    }

    pub async fn load() -> eyre::Result<Self> {
        let path = directories::ProjectDirs::from("", "forgejo-cli", "forgejo-cli")
            .ok_or_else(|| ftl_eyre!("msg-project-dir-not-found"))?
            .data_dir()
            .join("keys.json");
        let json = tokio::fs::read(path.as_path()).await;
        let this = match json {
            Ok(x) => serde_json::from_slice::<Self>(&x)?,
            Err(e) if e.kind() == ErrorKind::NotFound => {
                KeyInfo::load_fallback(path.as_path()).await?
            }
            Err(e) => return Err(e.into()),
        };
        Ok(this)
    }

    pub async fn save(&self) -> eyre::Result<()> {
        let json = serde_json::to_vec_pretty(self)?;
        let dirs = directories::ProjectDirs::from("", "forgejo-cli", "forgejo-cli")
            .ok_or_else(|| ftl_eyre!("msg-project-dir-not-found"))?;
        let path = dirs.data_dir();

        tokio::fs::create_dir_all(path).await?;

        let mut options = std::fs::OpenOptions::new();
        options.create(true).write(true).truncate(true);

        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }

        let mut file = tokio::fs::OpenOptions::from(options)
            .open(path.join("keys.json"))
            .await?;
        file.write_all(&json).await?;

        Ok(())
    }

    pub fn get_login(&mut self, url: &Url) -> Option<&mut LoginInfo> {
        let host = crate::host_name(url);
        let login_info = self.hosts.get_mut(host)?;
        Some(login_info)
    }

    pub async fn get_api(&mut self, url: &Url) -> eyre::Result<Forgejo> {
        match self.get_login(url) {
            Some(login) => {
                // Prefer the base URL saved at login; host_url may re-derive the wrong
                // scheme (e.g. a bare --host defaults to https).
                let api_url = login.base_url().cloned().unwrap_or_else(|| url.clone());
                let was_refreshed = login.refresh(&api_url).await?;
                let api = login.api_for(&api_url).await?;
                if was_refreshed {
                    self.save().await?;
                }
                Ok(api)
            }
            None => Forgejo::with_user_agent(Auth::None, url.clone(), crate::USER_AGENT)
                .map_err(Into::into),
        }
    }

    pub fn deref_alias(&self, url: url::Url) -> url::Url {
        match self.aliases.get(crate::host_name(&url)) {
            Some(replacement) => {
                let s = format!(
                    "{}{}{}",
                    &url[..url::Position::BeforeHost],
                    replacement,
                    &url[url::Position::AfterPort..]
                );
                url::Url::parse(&s).unwrap()
            }
            None => url,
        }
    }
}

#[derive(serde::Serialize, serde::Deserialize, Clone)]
#[serde(tag = "type")]
pub enum LoginInfo {
    Application {
        token: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        base_url: Option<Url>,
    },
    OAuth {
        token: String,
        refresh_token: String,
        expires_at: time::OffsetDateTime,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        base_url: Option<Url>,
    },
}

impl LoginInfo {
    async fn refresh(&mut self, url: &Url) -> eyre::Result<bool> {
        if let LoginInfo::OAuth {
            token,
            refresh_token,
            expires_at,
            ..
        } = self
        {
            if time::OffsetDateTime::now_utc() >= *expires_at {
                let api = Forgejo::with_user_agent(Auth::None, url.clone(), crate::USER_AGENT)?;
                let client_id = crate::auth::get_client_info_for(url)
                    .await?
                    .ok_or_else(|| eyre::eyre!("Can't refresh token: no client info for {url}."))?;
                let response = api
                    .oauth_get_access_token(forgejo_api::structs::OAuthTokenRequest::Refresh {
                        refresh_token,
                        client_id: &client_id,
                        client_secret: "",
                    })
                    .await?;
                *token = response.access_token;
                *refresh_token = response.refresh_token;
                // A minute less, in case any weirdness happens at the exact moment it
                // expires. Better to refresh slightly too soon than slightly too late.
                let expires_in =
                    std::time::Duration::from_secs(response.expires_in.saturating_sub(60) as u64);
                *expires_at = time::OffsetDateTime::now_utc() + expires_in;
                return Ok(true);
            }
        }
        Ok(false)
    }

    pub async fn api_for(&self, url: &Url) -> eyre::Result<Forgejo> {
        match self {
            LoginInfo::Application { token, .. } => {
                let api =
                    Forgejo::with_user_agent(Auth::Token(token), url.clone(), crate::USER_AGENT)?;
                Ok(api)
            }
            LoginInfo::OAuth { token, .. } => {
                let api =
                    Forgejo::with_user_agent(Auth::Token(token), url.clone(), crate::USER_AGENT)?;
                Ok(api)
            }
        }
    }

    pub fn base_url(&self) -> Option<&Url> {
        match self {
            LoginInfo::Application { base_url, .. } | LoginInfo::OAuth { base_url, .. } => {
                base_url.as_ref()
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn login_uses_saved_base_url() {
        // Logins are keyed by host name without scheme, so an https lookup
        // still finds an http login and recovers its saved base url.
        let login_url = Url::parse("http://forgejo.localhost:3000/").unwrap();
        let mut keys = KeyInfo::default();
        keys.hosts.insert(
            crate::host_name(&login_url).to_owned(),
            LoginInfo::Application {
                token: "t".into(),
                base_url: Some(login_url),
            },
        );

        let login = keys
            .get_login(&Url::parse("https://forgejo.localhost:3000/").unwrap())
            .unwrap();
        assert_eq!(login.base_url().unwrap().scheme(), "http");
    }

    #[test]
    fn old_config_loads_without_base_url() {
        let json = r#"{"type":"Application","token":"t"}"#;
        let info: LoginInfo = serde_json::from_str(json).unwrap();
        match info {
            LoginInfo::Application { token, base_url } => {
                assert_eq!(token, "t");
                assert!(base_url.is_none());
            }
            _ => unreachable!(),
        }
    }
}
