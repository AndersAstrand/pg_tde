# Encrypted data scope

`pg_tde` encrypts the following components:

* **User data** in tables using the extension, including associated TOAST data. The table metadata (column names, data types, etc.) is not encrypted.
* **Temporary tables** when they are created with the `tde_heap` access method. This does not include the temporary files PostgreSQL writes when queries exceed `work_mem` (sort or hash-join spill files) — those are not encrypted. See [Limitations of pg_tde](tde-limitations.md).
* **Write-Ahead Log (WAL) data** for the entire database cluster. This includes WAL data from both encrypted and non-encrypted tables.
* **Indexes** on encrypted tables.

[Check out the table access methods :material-arrow-right:](table-access-method.md){.md-button}
