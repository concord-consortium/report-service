export const productionGlossaryUrl = "https://lara2.concordqa.org";

export const productionGlossaries = [
  {
    "id": 8,
    "name": "Gas Laws 2020",
    "glossaryResourceId": "NciBizL2HUI7qiv3XdAB",
  },
  {
    "id": 9,
    "name": "Test Glossary",
    "glossaryResourceId": "OsuYZYOHoZKMVXMV2ijr",
  },
  {
    "id": 10,
    "name": "Wild Blueberries Lesson 1 Glossary",
    "glossaryResourceId": "aSkyVRFkmrnVDqIbxyIN",
  },
  {
    "id": 11,
    "name": "Wild Blueberries Lesson 2 Glossary",
    "glossaryResourceId": "lVXWBw9Wa1mTBkIlExXs",
  },
  {
    "id": 12,
    "name": "Wild Blueberries Lesson 3 Glossary",
    "glossaryResourceId": "fl8EYoUvUH5GX6D9qVik",
  },
  {
    "id": 13,
    "name": "Lake Ice-Out Lesson 1 Glossary",
    "glossaryResourceId": "WKGIe87AR1lBp56SmakN",
  },
  {
    "id": 14,
    "name": "Lake Ice-Out Lesson 2 Glossary",
    "glossaryResourceId": "ldArmSwDXRWM1viTO1c7",
  },
  {
    "id": 15,
    "name": "Lake Ice-Out Lesson 3 Glossary",
    "glossaryResourceId": "7WaEBOXFakRRoXOUDnDk",
  },
  {
    "id": 16,
    "name": "The Shape of Change Lesson 1 Glossary",
    "glossaryResourceId": "8smLeISuOtZ7ICCDgxGt",
  },
  {
    "id": 17,
    "name": "The Shape of Change Lesson 2 Glossary",
    "glossaryResourceId": "Mk3yfHrJbBRGDxNnGIS8",
  },
  {
    "id": 18,
    "name": "Ticks & Lyme Disease Lesson 1 Glossary",
    "glossaryResourceId": "cIjkFpLdV0bMLgHHHiem",
  },
  {
    "id": 19,
    "name": "Ticks & Lyme Disease Lesson 2 Glossary",
    "glossaryResourceId": "SKFnWkgfxXcTJaugMng4",
  },
  {
    "id": 20,
    "name": "Ticks & Lyme Disease Lesson 3 Glossary",
    "glossaryResourceId": "JaN86XReZl45mvcliiMY",
  },
  {
    "id": 21,
    "name": "Ticks & Lyme Disease Lesson 4 Glossary",
    "glossaryResourceId": "bfR5f6egaMAKaTHWXY0x",
  },
  {
    "id": 22,
    "name": "Lobster & Black Sea Bass Lesson 1 Glossary",
    "glossaryResourceId": "yBtnXkC6fIfXZ61zAjUg",
  },
  {
    "id": 23,
    "name": "Lobster & Black Sea Bass Lesson 2 Glossary",
    "glossaryResourceId": "wCUHdGfa7JnCuaWRujzF",
  },
  {
    "id": 24,
    "name": "Lobster & Black Sea Bass Lesson 3 Glossary",
    "glossaryResourceId": "1VKwXksQNLj7JBjRzbNe",
  },
  {
    "id": 25,
    "name": "Diffusion, osmosis, and active transport",
    "glossaryResourceId": "CBpP9TUgUGuUdDhliQNn",
  },
  {
    "id": 26,
    "name": "Bug Test Activity Glossary",
    "glossaryResourceId": "LvcQrzVvnl1Bm8sRKtHw",
  },
  {
    "id": 27,
    "name": "Kiley's Sample Glossary",
    "glossaryResourceId": "uGyUKyevEzJldnyYx4I0",
  },
  {
    "id": 28,
    "name": "V2PluginTestGlossary",
    "glossaryResourceId": "3Bn1CgFVH2oIpjV6242q",
 },
  {
    "id": 29,
    "name": "ER Glossary",
    "glossaryResourceId": "zE3QYVz8xJxomOQVvEbc",
  },
  {
    "id": 30,
    "name": "test glossary",
    "glossaryResourceId": "D9afwcpQ834e3XvKoak3",
  },
  {
    "id": 31,
    "name": "Test",
    "glossaryResourceId": "FLC50FXJVHBLjSMBkQks",
  },
  {
    "id": 32,
    "name": "DNA to Proteins",
    "glossaryResourceId": "hcV6fLyzTbRtB4KYFhxE",
  },
  {
    "id": 33,
    "name": "Test Glossary 1",
    "glossaryResourceId": "iWA7lhVgJX2ZyLoG7HXa",
  },
  {
    "id": 34,
    "name": "TestGlossaryPlugin",
    "glossaryResourceId": "H7yFsp4riXPRT8bRXd2J",
  },
  {
    "id": 35,
    "name": "heat and temperature",
    "glossaryResourceId": "Laz2d1NFDQTQ5uxvSNQd",
  },
  {
    "id": 36,
    "name": "PC Lesson 1 MA",
    "glossaryResourceId": "862154P6gx3V6oKtJRZw",
  },
  {
    "id": 37,
    "name": "PrecipitatingChange-AK-NE",
    "glossaryResourceId": "upZ83jqTZAZuoQqRAfAb"
  },
  {
    "id": 39,
    "name": "WATERS",
    "glossaryResourceId": "oRKDulC2nuAoBjeIaAIh"
  }
];


export const productionGlossaryIdMap: Record<string, number> = {};
productionGlossaries.forEach(item => {
  productionGlossaryIdMap[item.glossaryResourceId] = item.id;
});
