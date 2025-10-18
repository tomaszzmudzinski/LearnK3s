var builder = WebApplication.CreateBuilder(args);

builder.Services.AddOpenApi();

var app = builder.Build();

// Configure the HTTP request pipeline.
if (app.Environment.IsDevelopment())
{
    app.MapOpenApi();
}

// Add lightweight tracing headers so we can see which pod/node served the request
app.Use(async (ctx, next) =>
{
    var podName = Environment.GetEnvironmentVariable("POD_NAME") ?? Environment.MachineName;
    var nodeName = Environment.GetEnvironmentVariable("NODE_NAME") ?? "unknown";
    ctx.Response.OnStarting(() =>
    {
        ctx.Response.Headers["X-Pod-Name"] = podName;
        ctx.Response.Headers["X-Node-Name"] = nodeName;
        return Task.CompletedTask;
    });
    await next();
});

app.MapGet("/", () => Results.Ok());

app.MapGet("/health", () => Results.Ok("healthy"));

var summaries = new[]
{
    "Freezing", "Bracing", "Chilly", "Cool", "Mild", "Warm", "Balmy", "Hot", "Sweltering", "Scorching"
};

app.MapGet("/weatherforecast", () =>
{
    var forecast =  Enumerable.Range(1, 5).Select(index =>
        new WeatherForecast
        (
            DateOnly.FromDateTime(DateTime.Now.AddDays(index)),
            Random.Shared.Next(-20, 55),
            summaries[Random.Shared.Next(summaries.Length)]
        ))
        .ToArray();
    return forecast;
})
.WithName("GetWeatherForecast");

// Helpful endpoint to see routing clearly in the body
app.MapGet("/whoami", (HttpContext ctx) =>
{
    var podName = Environment.GetEnvironmentVariable("POD_NAME") ?? Environment.MachineName;
    var nodeName = Environment.GetEnvironmentVariable("NODE_NAME") ?? "unknown";
    var podIp = ctx.Connection.LocalIpAddress?.ToString();
    return Results.Ok(new
    {
        pod = podName,
        node = nodeName,
        podIp,
        timeUtc = DateTime.UtcNow
    });
});

app.Run();

record WeatherForecast(DateOnly Date, int TemperatureC, string? Summary)
{
    public int TemperatureF => 32 + (int)(TemperatureC / 0.5556);
}
