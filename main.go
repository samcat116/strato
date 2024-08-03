package main

import (
	"fmt"
	"log/slog"
	"net/http"
	"os"

	"encoding/json" // Add this line to import the "encoding/json" package

	"gorm.io/driver/postgres"
	"gorm.io/gorm"

	"github.com/google/uuid"
	"github.com/samcat116/strato/internal/models"
	// Add this line to import the "internal/models/vm" package
)

const qmpAddr = "unix:/path/to/qmp-socket"

var db *gorm.DB

func main() {
	logger := slog.New(slog.NewTextHandler(os.Stdout, nil))
	slog.SetDefault(logger)
	logger.Info("Starting Strato")

	logger.Info("Connecting to database")

	dbConnectionString := os.Getenv("DB_CONNECTION_STRING")
	var err error
	db, err = gorm.Open(postgres.Open(dbConnectionString), &gorm.Config{
		PrepareStmt: true,
	})
	if err != nil {
		logger.Error("Failed to connect to database")
	}

	if !db.Migrator().HasTable(&models.VirtualMachineDefinition{}) {
		fmt.Println("migrating")
		err = db.AutoMigrate(&models.VirtualMachineDefinition{})
		if err != nil {
			logger.Error("Failed to migrate database", "error", err)
			return
		}
		session := db.Session(&gorm.Session{PrepareStmt: true})
		if session != nil {
			fmt.Println("Migration successful")
		}
	}

	http.HandleFunc("/list", listVMs)
	http.HandleFunc("/create", createVM)
	http.HandleFunc("/delete", deleteVM)
	http.HandleFunc("/shutDownVM", shutDownVM)
	http.HandleFunc("/startVM", startVM)
	http.HandleFunc("/rebootVM", rebootVM)
	http.HandleFunc("/snapshotVM", snapshotVM)
	http.HandleFunc("/migrateVM", migrateVM)

	setupQEMU()

	http.ListenAndServe(":8080", nil)

}

func listVMs(w http.ResponseWriter, req *http.Request) {
	slog.Info("Getting VMs...")

	var vms []models.VirtualMachineDefinition
	result := db.Find(&vms)
	if result.Error != nil {
		slog.Error("Failed to get VMs")
		w.WriteHeader(http.StatusInternalServerError)

		return
	}
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(vms)

}

func createVM(w http.ResponseWriter, req *http.Request) {
	slog.Info("Creating VM...")
	randomName := uuid.New().String()
	vm := models.VirtualMachineDefinition{
		Name:   randomName,
		ID:     uuid.New(),
		VCPU:   2,
		Memory: 1024,
		Disk:   10,
	}
	fmt.Println(vm)

	result := db.Create(&vm)
	if result.Error != nil {
		slog.Error("Failed to create VM")
		w.WriteHeader(http.StatusInternalServerError)

		return
	}

	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(vm)

}

func deleteVM(w http.ResponseWriter, req *http.Request) {
	slog.Info("Deleting VM...")
}

func shutDownVM(w http.ResponseWriter, req *http.Request) {
	slog.Info("Shutting down VM...")
}

func startVM(w http.ResponseWriter, req *http.Request) {
	slog.Info("Starting VM...")
}

func rebootVM(w http.ResponseWriter, req *http.Request) {
	slog.Info("Rebooting VM...")
}

func snapshotVM(w http.ResponseWriter, req *http.Request) {
	slog.Info("Taking VM Snapshot...")
}

func migrateVM(w http.ResponseWriter, req *http.Request) {
	slog.Info("Migrating VM...")
}

func setupQEMU() {

}
