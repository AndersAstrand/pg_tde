# Using OpenBao as a key provider

You can configure `pg_tde` to use OpenBao as a global key provider for managing encryption keys securely.

!!! note
    This guide assumes that your OpenBao server is already set up and accessible. OpenBao configuration is outside the scope of this document, see [OpenBao's official documentation](https://openbao.org/docs/) for more information.

## Example usage

To register an OpenBao server as a global key provider:

```sql
SELECT pg_tde_add_global_key_provider_vault_v2(
    provider_name    => 'provider-name',
    vault_url        => 'url',
    vault_mount_path => 'mount',
    vault_token_path => 'secret_token_path',
    vault_ca_path    => 'ca_path',
    vault_namespace  => 'namespace'
);
```

## Parameter descriptions

* `provider_name` is the name to identify this key provider
* `vault_url` is the URL of the OpenBao server
* `vault_mount_path` is the mount point where the keyring should store the keys
* `vault_token_path` is a path to the file that contains an access token with read and write access to the above mount point
* [optional] `vault_ca_path` is the path of the CA file used for SSL verification
* [optional] `vault_namespace` is the namespace within the OpenBao server. Read more about the [namespace support in OpenBao](https://openbao.org/blog/namespaces-announcement/). You can use a `vault_namespace` without a `vault_ca_path`; in that case, pass `NULL` as the `vault_ca_path` value.

The following example is for testing purposes only. Use secure tokens and proper SSL validation in production environments:

```sql
SELECT pg_tde_add_global_key_provider_vault_v2(
    provider_name    => 'my-openbao-provider',
    vault_url        => 'https://openbao.example.com:8200',
    vault_mount_path => 'secret/data',
    vault_token_path => '/path/to/vault_token.txt',
    vault_ca_path    => '/path/to/ca_cert.pem',
    vault_namespace  => 'my-namespace'
);
```

For more information on related functions, see the link below:

[Percona pg_tde Function Reference](../functions.md){.md-button}

## Next steps

[Global Principal Key Configuration :material-arrow-right:](set-principal-key.md){.md-button}
