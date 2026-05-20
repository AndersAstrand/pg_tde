# KMIP configuration

To use a Key Management Interoperability Protocol (KMIP) server with `pg_tde`, you must configure it as a global key provider. This setup enables `pg_tde` to securely fetch and manage encryption keys from a centralized key management appliance.

!!! important
    When using HashiCorp Vault as a KMIP server, this configuration is not a validated deployment model for `pg_tde` and is not recommended for production use.

    For Vault-based key management, use the [KV v2 integration](vault.md) instead.

!!! note
    You need the root certificate of the KMIP server and a client key/certificate pair with permissions to create and read keys on the server.

For testing purposes, you can use a lightweight PyKMIP server, which enables easy certificate generation and basic KMIP behavior. If you're using a production-grade KMIP server, ensure you obtain valid, trusted certificates from the key management appliance.

## Example usage

```sql
SELECT pg_tde_add_global_key_provider_kmip(
    provider_name  => 'provider-name',
    kmip_host      => 'kmip-IP',
    kmip_port      => 5696,
    kmip_cert_path => '/path/to/client_cert.pem',
    kmip_key_path  => '/path/to/client_key.pem',
    kmip_ca_path   => '/path/to/server_ca.pem'
);
```

## Parameter descriptions

* `provider_name` is the name of the provider. You can specify any name, it's for you to identify the provider
* `kmip_host` is the IP address or domain name of the KMIP server
* `kmip_port` is the port to communicate with the KMIP server. Typically used port is 5696
* `kmip_cert_path` is the path to the client certificate.
* `kmip_key_path` is the path to the client key.
* `kmip_ca_path` is the path to the CA certificate used to validate the KMIP server's certificate. For self-signed test setups this may be the server's own certificate.

The following example is for testing purposes only.

```sql
SELECT pg_tde_add_global_key_provider_kmip(
    provider_name  => 'kmip',
    kmip_host      => '127.0.0.1',
    kmip_port      => 5696,
    kmip_cert_path => '/tmp/client_cert_jane_doe.pem',
    kmip_key_path  => '/tmp/client_key_jane_doe.pem',
    kmip_ca_path   => '/tmp/server_certificate.pem'
);
```

For more information on related functions, see the link below:

[Percona pg_tde Function Reference](../functions.md){.md-button}

## Next steps

[Global Principal Key Configuration :material-arrow-right:](set-principal-key.md){.md-button}
