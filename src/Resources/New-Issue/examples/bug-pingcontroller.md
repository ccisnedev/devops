---
title: 🐛 [Bug] PingController race condition: 'used after being disposed' en navegación Android
labels: bug,lifecycle,android,component-ping
---

# Descripción

Se está produciendo un error de race condition cuando se navega rápidamente en la aplicación Android. El `PingController` está siendo accedido después de haber sido disposed.

## Pasos para reproducir

1. Abrir la aplicación en un dispositivo Android
2. Navegar rápidamente entre pantallas que usan el PingController
3. El error aparece de forma intermitente

## Stack trace

```
Exception: A PingController was used after being disposed.
Once you have called dispose() on a PingController, it can no longer be used.
```

## Comportamiento esperado

El controller debería manejar correctamente su ciclo de vida y no ser accedido después de dispose.

## Comportamiento actual

Error intermitente cuando se navega rápidamente.

## Contexto adicional

- Versión de Flutter: 3.16.0
- Dispositivo: Android 13
- Frecuencia: Intermitente, ~30% de las navegaciones rápidas

## Posible solución

Implementar un flag `_disposed` para verificar el estado antes de hacer operaciones.
