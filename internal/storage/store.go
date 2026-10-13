package storage

import (
	"context"
	"github.com/proyecto-g7/transporte/internal/domain"
)

type Store interface {
	FindComplete(context.Context, string) (*domain.Manifest, error)
	Begin(context.Context, domain.Manifest) error
	WriteTrips(context.Context, []domain.Trip) error
	WriteWindows(context.Context, []domain.Window) error
	Complete(context.Context, domain.Manifest) error
	Fail(context.Context, domain.Manifest) error
	Close(context.Context) error
}
