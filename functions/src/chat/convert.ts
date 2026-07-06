import { Page, SectionType, LibraryInteractive, Plugin, EmbeddableType } from "./types";
import { productionGlossaryIdMap, productionGlossaryUrl } from "./glossary-info";

interface legacyEmbeddableBase {
  type: string;
  name?: string;
  authored_state?: string | null;
  interactiveState?: any | null;
  url_fragment?: string | null,
  is_hidden: boolean;
  is_full_width?: boolean;
  ref_id: string;
  embeddable_ref_id?: string;
}

interface IManagedInteractive extends legacyEmbeddableBase {
  type: "ManagedInteractive";
  library_interactive: LibraryInteractive | null;
  show_in_featured_question_report?: boolean;
  inherit_aspect_ratio_method?: boolean;
  custom_aspect_ratio_method?: "DEFAULT" | null;
  inherit_native_width?: boolean;
  custom_native_width?: number;
  inherit_native_height?: boolean;
  custom_native_height?: number;
  inherit_click_to_play?: boolean;
  custom_click_to_play?: boolean;
  inherit_full_window?: boolean;
  custom_full_window?: boolean;
  inherit_click_to_play_prompt?: boolean;
  custom_click_to_play_prompt?: string | null
  inherit_image_url?: boolean;
  custom_image_url?: string | null;
  linked_interactives?: { ref_id: string, label: string }[];
  linked_interactive?: { ref_id: string };
}

 interface IMwInteractive extends legacyEmbeddableBase {
  type: "MwInteractive";
  base_url?: string;
  url?: string;
  native_height?: number;
  native_width?: number;
  enable_learner_state?: boolean;
  show_delete_data_button?: boolean;
  linked_interactives?: { ref_id: string, label: string }[];
  linked_interactive?: { ref_id: string };
}

 interface IEmbeddableXhtml extends legacyEmbeddableBase {
  type: "Embeddable::Xhtml";
  content?: string;
  is_callout?: boolean;
}

 interface IEmbeddablePlugin extends legacyEmbeddableBase {
  type: "Embeddable::EmbeddablePlugin";
  plugin?: Plugin;
}

type legacyEmbeddableType = IManagedInteractive | IMwInteractive | IEmbeddableXhtml | IEmbeddablePlugin;
interface legacyEmbeddableWrapper {
  section: "header_block" | "interactive_box" | null;
  embeddable: legacyEmbeddableType;
}

type legacySection = Record<string, unknown>;
interface legacyPageType {
  embeddable_display_mode: "stacked" | "carousel";
  text?: string;
  is_completion: boolean;
  is_hidden: boolean;
  layout: string;
  id: number;
  name?: string | null;
  position: number,
  show_header?: boolean;
  show_info_assessment: boolean;
  show_interactive: boolean;
  show_sidebar: boolean;
  sidebar: string | null;
  sidebar_title: string | null;
  toggle_info_assessment: boolean;
  additional_sections: legacySection;        // update when we support additional sections
  embeddables: legacyEmbeddableWrapper[];
}

const getEmbeddablesArray = (embeddables: legacyEmbeddableType[], column: "primary" | "secondary" | null, embeddablesAreHidden: boolean): EmbeddableType[] => {
  const embeddableArr:EmbeddableType[] = [];
  embeddables.forEach((legacyEmbeddable: legacyEmbeddableType) => {
    const isHalfWidth = !legacyEmbeddable.is_full_width;
    delete legacyEmbeddable.is_full_width;
    legacyEmbeddable.is_hidden = embeddablesAreHidden || legacyEmbeddable.is_hidden;
    embeddableArr.push({column, is_half_width: isHalfWidth, ...legacyEmbeddable});
  });
  return embeddableArr;
};

const getPluginSection = (resourcePage: legacyPageType, embeddableWrapper: any): string | null | undefined => {
  if (embeddableWrapper.section === null && embeddableWrapper.embeddable.type === "Embeddable::EmbeddablePlugin") {
    const embeddableRefId = embeddableWrapper.embeddable.embeddable_ref_id;
    const foundEmbeddable =  resourcePage.embeddables.find(e => e.embeddable.ref_id === embeddableRefId);
    return foundEmbeddable?.section;
  }
  return undefined; // explicit return — report-service tsconfig sets noImplicitReturns:true
};

const newSectionsResource = (resourcePage: legacyPageType): SectionType[] => {
  const pageLayout = resourcePage.layout;
  let sectionLayout = "";
  switch (pageLayout) {
    case "l-full-width":
      sectionLayout = "full-width";
      break;
    case "l-responsive":
      sectionLayout  = "responsive";
      break;
    case "l-responsive-50-50":
      sectionLayout  = "responsive-50-50";
      break;
    case "l-6040":
      sectionLayout = "40-60";
      break;
    case "r-4060":
      sectionLayout = "60-40";
      break;
    case "l-7030":
      sectionLayout = "30-70";
      break;
    case "r-3070":
      sectionLayout = "70-30";
  }
  const headerBlockEmbeddables: legacyEmbeddableType[] = [];
  const primaryBlockEmbeddables: legacyEmbeddableType[] = [];
  const secondaryBlockEmbeddables: legacyEmbeddableType[] = [];
  const newSections: SectionType[] = [];
  const headerBlockHidden = !resourcePage.show_header || false;
  const primaryBlockHidden = !resourcePage.show_interactive;
  const secondaryBlockHidden = !resourcePage.show_info_assessment;

  resourcePage.embeddables?.forEach((embeddableWrapper: any) => {
    const section = embeddableWrapper.section;
    const pluginSection = getPluginSection(resourcePage, embeddableWrapper);

    if (section === "header_block" || pluginSection === "header_block") {
        headerBlockEmbeddables.push(embeddableWrapper.embeddable);
    } else if (section === "interactive_box" || pluginSection === "interactive_box") {
        primaryBlockEmbeddables.push(embeddableWrapper.embeddable);
    } else {
      secondaryBlockEmbeddables.push(embeddableWrapper.embeddable);
    }
  });

  const headerBlockSection = {
    "layout": "full-width",
    "is_hidden": headerBlockHidden,
    "secondary_column_collapsible": false,
    "secondary_column_display_mode": "stacked" as "stacked" | "carousel",
    "embeddables": getEmbeddablesArray(headerBlockEmbeddables, null, headerBlockHidden)
  };
  const splitBlockSection = {
    "layout": sectionLayout,
    "is_hidden": primaryBlockHidden && secondaryBlockHidden,
    "secondary_column_collapsible": resourcePage.toggle_info_assessment,
    "secondary_column_display_mode": resourcePage.embeddable_display_mode,
    "embeddables": getEmbeddablesArray(primaryBlockEmbeddables, "primary", primaryBlockHidden).concat(getEmbeddablesArray(secondaryBlockEmbeddables, "secondary", secondaryBlockHidden))
  };

  headerBlockSection.embeddables.length > 0 && newSections.push(headerBlockSection);
  splitBlockSection.embeddables.length > 0 && newSections.push(splitBlockSection);

  return newSections;
};

const newPagesResource = (resourcePages: any):Page[] => {
  return (
    resourcePages.map((page: legacyPageType) => {
      return {
        "text": page.text,
        "id": page.id,
        "is_completion": page.is_completion,
        "is_hidden": page.is_hidden,
        "name": page.name,
        "position": page.position,
        "show_sidebar": page.show_sidebar,
        "sidebar": page.sidebar,
        "sidebar_title": page.sidebar_title,
        "sections": newSectionsResource(page)
      };
    })
  );
};

const convertGlossaryPlugins = (plugins: any[]) => {
  // Return a new array of shallow-cloned plugins (no parameter/loop-var reassignment — tslint
  // no-parameter-reassignment is an error in the report-service functions workspace).
  return plugins.map(plugin => {
    const converted = { ...plugin };
    if (converted.approved_script_label === "glossary") {
      try {
        const authorData = JSON.parse(converted.author_data);
        if (authorData?.glossaryResourceId && productionGlossaryIdMap[authorData?.glossaryResourceId]) {
          const id = productionGlossaryIdMap[authorData.glossaryResourceId];
          authorData.glossaryResourceId = "this-is-a-fake-CONVERTED-glossary-resource-id";
          authorData.s3Url = `${productionGlossaryUrl}/api/v1/glossaries/${id}?json_only=true`;
          converted.author_data = JSON.stringify(authorData);
        }
      } catch (e) {
        // noop
      }
    }
    return converted;
  });
};

function convertActivityResource (legacyResource: any) {
  const newActivityResource = {
    "id": legacyResource.id,
    "background_image": legacyResource.background_image,
    "fixed_width_layout": legacyResource.fixed_width_layout,
    "description": legacyResource.description,
    "editor_mode": legacyResource.editor_mode,
    "layout": legacyResource.layout,
    "name": legacyResource.name,
    "notes": legacyResource.notes,
    "related": legacyResource.related,
    "show_submit_button": legacyResource.show_submit_button,
    "student_report_enabled": legacyResource.student_report_enabled,
    "thumbnail_url": legacyResource.thumbnail_url,
    "time_to_complete": legacyResource.time_to_complete,
    "version": 2,
    "theme_name": legacyResource.theme_name,
    "project": legacyResource.project,
    "plugins": legacyResource.plugins ? convertGlossaryPlugins(legacyResource.plugins) : [], // guard missing plugins
    "type": "LightweightActivity",
    "export_site": legacyResource.export_site,
    "pages": newPagesResource(legacyResource.pages),
    "defunct": legacyResource.defunct,
    "hide_read_aloud": legacyResource.hide_read_aloud,
    "hide_question_numbers": legacyResource.hide_question_numbers,
    "font_size": legacyResource.font_size,
  };
  return newActivityResource;
}
const getSequenceActivities = (seqActivities: any) => {
  const activityArr: any[] = [];
  seqActivities.forEach((seqActivity:any) => {
    const act:any = convertActivityResource(seqActivity);
    activityArr.push(act);
  });
  return activityArr;
};

const newSequenceResource = (sequenceResource: any) => {
  return (
    {
      "abstract": sequenceResource.abstract,
      "description": sequenceResource.description,
      "display_title": sequenceResource.display_title,
      "logo": sequenceResource.logo,
      "project": sequenceResource.project,
      "theme_id": sequenceResource.theme_id,
      "background_image": sequenceResource.background_image,
      "thumbnail_url": sequenceResource.thumbnail_url,
      "title": sequenceResource.title,
      "type": sequenceResource.type,
      "export_site": sequenceResource.export_site,
      "activities": getSequenceActivities(sequenceResource.activities),
      "defunct": sequenceResource.defunct,
      "hide_read_aloud": sequenceResource.hide_read_aloud,
      "font_size": sequenceResource.font_size,
      "layout_override": sequenceResource.layout_override,
    }
  );
};

export const convertLegacyResource = (legacyRes: any) => {
  let r = {};
  if (legacyRes.activities) {
    r = newSequenceResource(legacyRes);
  } else {
    r = convertActivityResource(legacyRes);
  }
  return r;
};
