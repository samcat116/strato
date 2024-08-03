package db

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"os"
	"strconv"

	"gorm.io/driver/postgres"
	"gorm.io/gorm"

	"github.com/google/uuid"

)

var DB *gorm.DB

func setupDB() {
	
}

func contstuctDNS() *DSN {
	host, hostDefined := os.LookupEnv("DB_HOST")

	user, userDefined := os.LookupEnv("DB_USER")
	dbname, dbDefined := os.LookupEnv("DB_DATABASE")
	portStr, portDefined := os.LookupEnv("DB_PORT")
	ssl, sslDefined := os.LookupEnv("DB_SSL")

	port, err := strconv.Atoi(portStr)
	if err != nil {
		
	}


	if hostDefined && userDefined && dbDefined && portDefined && sslDefined {
		dsn := DSN{
			Host:    host,
			User:    user,
			DBname:  dbname,
			Port:    port,
			SSLmode: ssl,
		}
	}
}

type DSN struct {
	Host string
	User string
	DBname string
	Port int
	SSLmode	bool

}
