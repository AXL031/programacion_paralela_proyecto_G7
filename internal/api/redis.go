package api

import (
	"context"
	"github.com/redis/go-redis/v9"
	"time"
)

type RedisCache struct{ Client *redis.Client }

func (r RedisCache) Get(ctx context.Context, key string) (string, error) {
	value, err := r.Client.Get(ctx, key).Result()
	if err == redis.Nil {
		return "", nil
	}
	return value, err
}
func (r RedisCache) Set(ctx context.Context, key, value string, ttl time.Duration) error {
	return r.Client.Set(ctx, key, value, ttl).Err()
}
