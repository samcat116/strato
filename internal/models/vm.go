package models

import (
	"github.com/google/uuid"
)

type VirtualMachineDefinition struct {
	Name   string
	ID     uuid.UUID `gorm:"primaryKey"`
	VCPU   int       `gorm:"not null"`
	Memory int       `gorm:"not null"`
	Disk   int       `gorm:"not null"`
}
