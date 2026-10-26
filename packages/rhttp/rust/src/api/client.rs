use crate::api::error::RhttpError;
use crate::api::http::HttpVersionPref;
use flutter_rust_bridge::{frb, DartFnFuture};
use std::collections::HashMap;
use std::sync::Arc;
pub use tokio_util::sync::CancellationToken;

pub struct ClientSettings {
    pub cookie_settings: Option<CookieSettings>,
    pub http_version_pref: HttpVersionPref,
    pub timeout_settings: Option<TimeoutSettings>,
    pub throw_on_status_code: bool,
    pub proxy_settings: Option<ProxySettings>,
    pub redirect_settings: Option<RedirectSettings>,
    pub tls_settings: Option<TlsSettings>,
    pub dns_settings: Option<DnsSettings>,
    pub user_agent: Option<String>,
}

pub struct CookieSettings {
    pub store_cookies: bool,
}

pub enum ProxySettings {
    NoProxy,
    CustomProxyList(Vec<CustomProxy>),
}

pub struct CustomProxy {
    pub url: String,
    pub condition: ProxyCondition,
}

pub enum ProxyCondition {
    Http,
    Https,
    All,
}

pub enum RedirectSettings {
    NoRedirect,
    LimitedRedirects(i32),
}

pub struct TimeoutSettings {
    pub timeout: Option<chrono::Duration>,
    pub connect_timeout: Option<chrono::Duration>,
    pub keep_alive_timeout: Option<chrono::Duration>,
    pub keep_alive_ping: Option<chrono::Duration>,
}

pub struct TlsSettings {
    pub trust_root_certificates: bool,
    pub trusted_root_certificates: Vec<Vec<u8>>,
    pub verify_certificates: bool,
    pub client_certificate: Option<ClientCertificate>,
    pub min_tls_version: Option<TlsVersion>,
    pub max_tls_version: Option<TlsVersion>,
    pub sni: bool,
}

pub enum DnsSettings {
    StaticDns(StaticDnsSettings),
    DynamicDns(DynamicDnsSettings),
}

pub struct StaticDnsSettings {
    pub overrides: HashMap<String, Vec<String>>,
    pub fallback: Option<String>,
}

pub struct DynamicDnsSettings {
    /// A function that takes a hostname and returns a future that resolves to an IP address.
    resolver: Arc<dyn Fn(String) -> DartFnFuture<Vec<String>> + 'static + Send + Sync>,
}

pub struct ClientCertificate {
    pub certificate: Vec<u8>,
    pub private_key: Vec<u8>,
}

pub enum TlsVersion {
    Tls1_2,
    Tls1_3,
}

impl Default for ClientSettings {
    fn default() -> Self {
        ClientSettings {
            cookie_settings: None,
            http_version_pref: HttpVersionPref::All,
            timeout_settings: None,
            throw_on_status_code: true,
            proxy_settings: None,
            redirect_settings: None,
            tls_settings: None,
            dns_settings: None,
            user_agent: None,
        }
    }
}

/// Wraps the Dart-provided resolver into the UI-neutral contract owned by
/// `rhttp-core`. A future uniffi adapter implements the same trait with a
/// callback interface instead.
struct DartDnsResolver(Arc<dyn Fn(String) -> DartFnFuture<Vec<String>> + 'static + Send + Sync>);

impl rhttp_core::DnsResolver for DartDnsResolver {
    fn resolve(&self, host: String) -> rhttp_core::DnsFuture {
        let fut = (self.0)(host);
        Box::pin(async move { fut.await })
    }
}

impl ClientSettings {
    pub(crate) fn into_core(self) -> rhttp_core::ClientSettings {
        rhttp_core::ClientSettings {
            cookie_settings: self
                .cookie_settings
                .map(|s| rhttp_core::CookieSettings {
                    store_cookies: s.store_cookies,
                }),
            http_version_pref: match self.http_version_pref {
                HttpVersionPref::Http10 => rhttp_core::HttpVersionPref::Http10,
                HttpVersionPref::Http11 => rhttp_core::HttpVersionPref::Http11,
                HttpVersionPref::Http2 => rhttp_core::HttpVersionPref::Http2,
                HttpVersionPref::Http3 => rhttp_core::HttpVersionPref::Http3,
                HttpVersionPref::All => rhttp_core::HttpVersionPref::All,
            },
            timeout_settings: self
                .timeout_settings
                .map(|s| rhttp_core::TimeoutSettings {
                    timeout: s.timeout,
                    connect_timeout: s.connect_timeout,
                    keep_alive_timeout: s.keep_alive_timeout,
                    keep_alive_ping: s.keep_alive_ping,
                }),
            throw_on_status_code: self.throw_on_status_code,
            proxy_settings: self.proxy_settings.map(|p| match p {
                ProxySettings::NoProxy => rhttp_core::ProxySettings::NoProxy,
                ProxySettings::CustomProxyList(list) => {
                    rhttp_core::ProxySettings::CustomProxyList(
                        list.into_iter()
                            .map(|p| rhttp_core::CustomProxy {
                                url: p.url,
                                condition: match p.condition {
                                    ProxyCondition::Http => rhttp_core::ProxyCondition::Http,
                                    ProxyCondition::Https => rhttp_core::ProxyCondition::Https,
                                    ProxyCondition::All => rhttp_core::ProxyCondition::All,
                                },
                            })
                            .collect(),
                    )
                }
            }),
            redirect_settings: self.redirect_settings.map(|r| match r {
                RedirectSettings::NoRedirect => rhttp_core::RedirectSettings::NoRedirect,
                RedirectSettings::LimitedRedirects(n) => {
                    rhttp_core::RedirectSettings::LimitedRedirects(n)
                }
            }),
            tls_settings: self.tls_settings.map(|t| rhttp_core::TlsSettings {
                trust_root_certificates: t.trust_root_certificates,
                trusted_root_certificates: t.trusted_root_certificates,
                verify_certificates: t.verify_certificates,
                client_certificate: t
                    .client_certificate
                    .map(|c| rhttp_core::ClientCertificate {
                        certificate: c.certificate,
                        private_key: c.private_key,
                    }),
                min_tls_version: t.min_tls_version.map(|v| match v {
                    TlsVersion::Tls1_2 => rhttp_core::TlsVersion::Tls1_2,
                    TlsVersion::Tls1_3 => rhttp_core::TlsVersion::Tls1_3,
                }),
                max_tls_version: t.max_tls_version.map(|v| match v {
                    TlsVersion::Tls1_2 => rhttp_core::TlsVersion::Tls1_2,
                    TlsVersion::Tls1_3 => rhttp_core::TlsVersion::Tls1_3,
                }),
                sni: t.sni,
            }),
            dns_settings: self.dns_settings.map(|d| match d {
                DnsSettings::StaticDns(s) => {
                    rhttp_core::DnsSettings::StaticDns(rhttp_core::StaticDnsSettings {
                        overrides: s.overrides,
                        fallback: s.fallback,
                    })
                }
                DnsSettings::DynamicDns(s) => {
                    rhttp_core::DnsSettings::DynamicDns(rhttp_core::DynamicDnsSettings {
                        resolver: Arc::new(DartDnsResolver(s.resolver)),
                    })
                }
            }),
            user_agent: self.user_agent,
        }
    }
}

#[derive(Clone)]
pub struct RequestClient {
    /// The UI-neutral core client. The FRB surface stays opaque; uniffi can
    /// expose the same core type without going through this wrapper.
    pub(crate) core: rhttp_core::CoreRequestClient,
}

impl RequestClient {
    pub(crate) fn new(settings: ClientSettings) -> Result<RequestClient, RhttpError> {
        create_client(settings)
    }
}

fn create_client(settings: ClientSettings) -> Result<RequestClient, RhttpError> {
    let core = rhttp_core::build_client(settings.into_core()).map_err(RhttpError::from)?;
    Ok(RequestClient { core })
}

#[frb(sync)]
pub fn create_static_resolver_sync(settings: StaticDnsSettings) -> DnsSettings {
    DnsSettings::StaticDns(settings)
}

#[frb(sync)]
pub fn create_dynamic_resolver_sync(
    resolver: impl Fn(String) -> DartFnFuture<Vec<String>> + 'static + Send + Sync,
) -> DnsSettings {
    DnsSettings::DynamicDns(DynamicDnsSettings {
        resolver: Arc::new(resolver),
    })
}
