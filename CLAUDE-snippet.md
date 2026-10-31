# Optional agent instruction for ctrl-ccv

When the user refers to a recently copied Windows screenshot, inspect the
configured remote image path directly. By default that is:

```text
~/clipboard-images/latest.png
```

If the ctrl-ccv configuration uses another `RemoteDir`, substitute that path.
Do not assume a particular SSH hostname, Linux username, Cloudflare setup, or
agent product.
