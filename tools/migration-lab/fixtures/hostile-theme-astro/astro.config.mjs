// Never executed. Hostile sidebar + external link evidence.
export default {
  integrations: [
    {
      name: "fake-starlight",
      sidebar: [
        { label: "Trap", link: "https://evil.example/nav" },
        { autogenerate: { directory: "../outside" } },
      ],
    },
  ],
};
