# /etc/server-backup/dumps.sh: по одной строке на каждую базу на сервере. Функции описаны в backup.sh.
# Если баз нет, файл остаётся пустым. Другой тип базы: допиши такую же функцию, она должна падать на пустом или нечитаемом дампе.

# dump_sqlite /opt/app/data/app.db app
# dump_postgres_docker app-db-1 app appdb
# dump_postgres_local appdb
# dump_mysql_docker wp-db-1 wordpress
