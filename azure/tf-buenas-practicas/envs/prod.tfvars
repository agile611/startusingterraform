proyecto            = "webapp"
entorno             = "prod"
storage_replicacion = "GRS"
subredes = {
  web  = "10.0.1.0/24"
  api  = "10.0.2.0/24"
  data = "10.0.3.0/24"
}
tags = {
  propietario = "equipo-web"
  coste       = "CC-1001"
  criticidad  = "alta"
}
