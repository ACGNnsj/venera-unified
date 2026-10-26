use crate::error::CoreError;
use crate::settings::*;
use crate::socket_addr::SocketAddrDigester;
use reqwest::dns::{Addrs, Name, Resolve, Resolving};
use reqwest::{tls, Certificate};
use std::net::SocketAddr;
use std::str::FromStr;
use std::sync::Arc;
use tokio_util::sync::CancellationToken;

/// A reqwest client plus the settings needed by the request layer.
///
/// This type intentionally has no Flutter Rust Bridge dependency. The FRB
/// adapter wraps it in an opaque handle; uniffi can export it directly.
#[derive(Clone)]
pub struct CoreRequestClient {
    pub client: reqwest::Client,
    pub http_version_pref: HttpVersionPref,
    pub throw_on_status_code: bool,
    /// A token that can be used to cancel all requests made by this client.
    pub cancel_token: CancellationToken,
}

pub fn build_client(settings: ClientSettings) -> Result<CoreRequestClient, CoreError> {
    let client: reqwest::Client = {
        let mut client = reqwest::Client::builder();
        if let Some(proxy_settings) = settings.proxy_settings {
            match proxy_settings {
                ProxySettings::NoProxy => client = client.no_proxy(),
                ProxySettings::CustomProxyList(proxies) => {
                    for proxy in proxies {
                        let proxy = match proxy.condition {
                            ProxyCondition::Http => reqwest::Proxy::http(&proxy.url),
                            ProxyCondition::Https => reqwest::Proxy::https(&proxy.url),
                            ProxyCondition::All => reqwest::Proxy::all(&proxy.url),
                        }
                        .map_err(|e| CoreError::Unknown(format!("Error creating proxy: {e:?}")))?;
                        client = client.proxy(proxy);
                    }
                }
            }
        }

        if let Some(cookie_settings) = settings.cookie_settings {
            client = client.cookie_store(cookie_settings.store_cookies);
        }

        if let Some(redirect_settings) = settings.redirect_settings {
            client = match redirect_settings {
                RedirectSettings::NoRedirect => client.redirect(reqwest::redirect::Policy::none()),
                RedirectSettings::LimitedRedirects(max_redirects) => {
                    client.redirect(reqwest::redirect::Policy::limited(max_redirects as usize))
                }
            };
        }

        if let Some(timeout_settings) = settings.timeout_settings {
            if let Some(timeout) = timeout_settings.timeout {
                client = client.timeout(
                    timeout
                        .to_std()
                        .map_err(|e| CoreError::Unknown(e.to_string()))?,
                );
            }
            if let Some(timeout) = timeout_settings.connect_timeout {
                client = client.connect_timeout(
                    timeout
                        .to_std()
                        .map_err(|e| CoreError::Unknown(e.to_string()))?,
                );
            }

            if let Some(keep_alive_timeout) = timeout_settings.keep_alive_timeout {
                let timeout = keep_alive_timeout
                    .to_std()
                    .map_err(|e| CoreError::Unknown(e.to_string()))?;
                if timeout.as_millis() > 0 {
                    client = client.tcp_keepalive(timeout);
                    client = client.http2_keep_alive_while_idle(true);
                    client = client.http2_keep_alive_timeout(timeout);
                }
            }

            if let Some(keep_alive_ping) = timeout_settings.keep_alive_ping {
                client = client.http2_keep_alive_interval(
                    keep_alive_ping
                        .to_std()
                        .map_err(|e| CoreError::Unknown(e.to_string()))?,
                );
            }
        }

        if let Some(tls_settings) = settings.tls_settings {
            if !tls_settings.trust_root_certificates {
                client = client.tls_built_in_root_certs(false);
            }

            for cert in tls_settings.trusted_root_certificates {
                client =
                    client.add_root_certificate(Certificate::from_pem(&cert).map_err(|e| {
                        CoreError::Unknown(format!("Error adding trusted certificate: {e:?}"))
                    })?);
            }

            if !tls_settings.verify_certificates {
                client = client.danger_accept_invalid_certs(true);
            }

            if let Some(client_certificate) = tls_settings.client_certificate {
                let identity = &[
                    client_certificate.certificate.as_slice(),
                    "\\n".as_bytes(),
                    client_certificate.private_key.as_slice(),
                ]
                .concat();

                client = client.identity(
                    reqwest::Identity::from_pem(identity)
                        .map_err(|e| CoreError::Unknown(format!("{e:?}")))?,
                );
            }

            if let Some(min_tls_version) = tls_settings.min_tls_version {
                client = client.min_tls_version(match min_tls_version {
                    TlsVersion::Tls1_2 => tls::Version::TLS_1_2,
                    TlsVersion::Tls1_3 => tls::Version::TLS_1_3,
                });
            }

            if let Some(max_tls_version) = tls_settings.max_tls_version {
                client = client.max_tls_version(match max_tls_version {
                    TlsVersion::Tls1_2 => tls::Version::TLS_1_2,
                    TlsVersion::Tls1_3 => tls::Version::TLS_1_3,
                });
            }

            client = client.tls_sni(tls_settings.sni);
        }

        client = match settings.http_version_pref {
            HttpVersionPref::Http10 | HttpVersionPref::Http11 => client.http1_only(),
            HttpVersionPref::Http2 => client.http2_prior_knowledge(),
            HttpVersionPref::Http3 => client.http3_prior_knowledge(),
            HttpVersionPref::All => client,
        };

        if let Some(dns_settings) = settings.dns_settings {
            match dns_settings {
                DnsSettings::StaticDns(settings) => {
                    if let Some(fallback) = settings.fallback {
                        client = client.dns_resolver(Arc::new(StaticResolver {
                            address: SocketAddr::from_str(fallback.digest_ip().as_str())
                                .map_err(|e| CoreError::Unknown(format!("{e:?}")))?,
                        }));
                    }

                    for dns_override in settings.overrides {
                        let (hostname, ip) = dns_override;
                        let hostname = hostname.as_str();
                        let mut err: Option<String> = None;
                        let ip = ip
                            .into_iter()
                            .map(|ip| {
                                let ip_digested = ip.digest_ip();
                                SocketAddr::from_str(ip_digested.as_str()).map_err(|e| {
                                    err = Some(format!("Invalid IP address: {ip_digested}. {e:?}"));
                                    CoreError::Unknown(e.to_string())
                                })
                            })
                            .filter_map(Result::ok)
                            .collect::<Vec<SocketAddr>>();

                        if let Some(error) = err {
                            return Err(CoreError::Unknown(error));
                        }

                        client = client.resolve_to_addrs(hostname, ip.as_slice());
                    }
                }
                DnsSettings::DynamicDns(settings) => {
                    client = client.dns_resolver(Arc::new(DynamicResolver {
                        resolver: settings.resolver,
                    }));
                }
            }
        }

        if let Some(user_agent) = settings.user_agent {
            client = client.user_agent(user_agent);
        }

        client
            .build()
            .map_err(|e| CoreError::Unknown(format!("{e:?}")))?
    };

    Ok(CoreRequestClient {
        client,
        http_version_pref: settings.http_version_pref,
        throw_on_status_code: settings.throw_on_status_code,
        cancel_token: CancellationToken::new(),
    })
}

struct StaticResolver {
    address: SocketAddr,
}

impl Resolve for StaticResolver {
    fn resolve(&self, _: Name) -> Resolving {
        let addrs: Addrs = Box::new(vec![self.address].into_iter());
        Box::pin(futures_util::future::ready(Ok(addrs)))
    }
}

struct DynamicResolver {
    resolver: Arc<dyn DnsResolver>,
}

impl Resolve for DynamicResolver {
    fn resolve(&self, name: Name) -> Resolving {
        let resolver = self.resolver.clone();
        Box::pin(async move {
            let ip = resolver.resolve(name.as_str().to_owned()).await;
            let ip = ip
                .into_iter()
                .map(|ip| {
                    let ip_digested = ip.digest_ip();
                    SocketAddr::from_str(ip_digested.as_str()).map_err(|e| {
                        CoreError::Unknown(format!("Invalid IP address: {ip_digested}. {e:?}"))
                    })
                })
                .filter_map(Result::ok)
                .collect::<Vec<SocketAddr>>();

            let addrs: Addrs = Box::new(ip.into_iter());
            Ok(addrs)
        })
    }
}
