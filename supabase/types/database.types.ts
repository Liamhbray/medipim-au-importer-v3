export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  graphql_public: {
    Tables: {
      [_ in never]: never
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      graphql: {
        Args: {
          operationName?: string
          query?: string
          variables?: Json
          extensions?: Json
        }
        Returns: Json
      }
    }
    Enums: {
      [_ in never]: never
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
  public: {
    Tables: {
      active_ingredients: {
        Row: {
          id: number
          name_en: string | null
          raw_data: Json | null
        }
        Insert: {
          id: number
          name_en?: string | null
          raw_data?: Json | null
        }
        Update: {
          id?: number
          name_en?: string | null
          raw_data?: Json | null
        }
        Relationships: []
      }
      brands: {
        Row: {
          id: number
          name: string | null
          raw_data: Json | null
        }
        Insert: {
          id: number
          name?: string | null
          raw_data?: Json | null
        }
        Update: {
          id?: number
          name?: string | null
          raw_data?: Json | null
        }
        Relationships: []
      }
      deferred_relationships: {
        Row: {
          created_at: string | null
          entity_id: string
          entity_type: string
          id: number
          relationship_data: Json
          relationship_type: string
        }
        Insert: {
          created_at?: string | null
          entity_id: string
          entity_type: string
          id?: number
          relationship_data: Json
          relationship_type: string
        }
        Update: {
          created_at?: string | null
          entity_id?: string
          entity_type?: string
          id?: number
          relationship_data?: Json
          relationship_type?: string
        }
        Relationships: []
      }
      media: {
        Row: {
          id: number
          photo_type: string | null
          raw_data: Json | null
          storage_path: string | null
          type: string | null
        }
        Insert: {
          id: number
          photo_type?: string | null
          raw_data?: Json | null
          storage_path?: string | null
          type?: string | null
        }
        Update: {
          id?: number
          photo_type?: string | null
          raw_data?: Json | null
          storage_path?: string | null
          type?: string | null
        }
        Relationships: []
      }
      organizations: {
        Row: {
          id: number
          name: string | null
          raw_data: Json | null
          type: string | null
        }
        Insert: {
          id: number
          name?: string | null
          raw_data?: Json | null
          type?: string | null
        }
        Update: {
          id?: number
          name?: string | null
          raw_data?: Json | null
          type?: string | null
        }
        Relationships: []
      }
      product_brands: {
        Row: {
          brand_id: number
          product_id: string
        }
        Insert: {
          brand_id: number
          product_id: string
        }
        Update: {
          brand_id?: number
          product_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "product_brands_brand_id_fkey"
            columns: ["brand_id"]
            isOneToOne: false
            referencedRelation: "brands"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "product_brands_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id"]
          },
        ]
      }
      product_categories: {
        Row: {
          category_id: number
          product_id: string
        }
        Insert: {
          category_id: number
          product_id: string
        }
        Update: {
          category_id?: number
          product_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "product_categories_category_id_fkey"
            columns: ["category_id"]
            isOneToOne: false
            referencedRelation: "public_categories"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "product_categories_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id"]
          },
        ]
      }
      product_families: {
        Row: {
          id: number
          name_en: string | null
          raw_data: Json | null
        }
        Insert: {
          id: number
          name_en?: string | null
          raw_data?: Json | null
        }
        Update: {
          id?: number
          name_en?: string | null
          raw_data?: Json | null
        }
        Relationships: []
      }
      product_media: {
        Row: {
          media_id: number
          product_id: string
        }
        Insert: {
          media_id: number
          product_id: string
        }
        Update: {
          media_id?: number
          product_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "product_media_media_id_fkey"
            columns: ["media_id"]
            isOneToOne: false
            referencedRelation: "media"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "product_media_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id"]
          },
        ]
      }
      product_organizations: {
        Row: {
          organization_id: number
          product_id: string
        }
        Insert: {
          organization_id: number
          product_id: string
        }
        Update: {
          organization_id?: number
          product_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "product_organizations_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "product_organizations_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id"]
          },
        ]
      }
      products: {
        Row: {
          artg_id: string | null
          biocide: boolean | null
          created_at: number | null
          ean: string[] | null
          ean_gtin12: string | null
          ean_gtin13: string | null
          ean_gtin14: string | null
          ean_gtin8: string | null
          fred: string | null
          id: string
          manufacturer_price: number | null
          name_en: string | null
          pbs: string | null
          pharmacist_price: number | null
          public_price: number | null
          raw_data: Json | null
          replacement: string | null
          requires_legal_text: boolean | null
          seo_name_en: string | null
          snomed_ctpp: string | null
          snomed_mp: string | null
          snomed_mpp: string | null
          snomed_mpuu: string | null
          snomed_tp: string | null
          snomed_tpp: string | null
          snomed_tpuu: string | null
          status: string | null
          updated_at: number | null
          z_code: string | null
        }
        Insert: {
          artg_id?: string | null
          biocide?: boolean | null
          created_at?: number | null
          ean?: string[] | null
          ean_gtin12?: string | null
          ean_gtin13?: string | null
          ean_gtin14?: string | null
          ean_gtin8?: string | null
          fred?: string | null
          id: string
          manufacturer_price?: number | null
          name_en?: string | null
          pbs?: string | null
          pharmacist_price?: number | null
          public_price?: number | null
          raw_data?: Json | null
          replacement?: string | null
          requires_legal_text?: boolean | null
          seo_name_en?: string | null
          snomed_ctpp?: string | null
          snomed_mp?: string | null
          snomed_mpp?: string | null
          snomed_mpuu?: string | null
          snomed_tp?: string | null
          snomed_tpp?: string | null
          snomed_tpuu?: string | null
          status?: string | null
          updated_at?: number | null
          z_code?: string | null
        }
        Update: {
          artg_id?: string | null
          biocide?: boolean | null
          created_at?: number | null
          ean?: string[] | null
          ean_gtin12?: string | null
          ean_gtin13?: string | null
          ean_gtin14?: string | null
          ean_gtin8?: string | null
          fred?: string | null
          id?: string
          manufacturer_price?: number | null
          name_en?: string | null
          pbs?: string | null
          pharmacist_price?: number | null
          public_price?: number | null
          raw_data?: Json | null
          replacement?: string | null
          requires_legal_text?: boolean | null
          seo_name_en?: string | null
          snomed_ctpp?: string | null
          snomed_mp?: string | null
          snomed_mpp?: string | null
          snomed_mpuu?: string | null
          snomed_tp?: string | null
          snomed_tpp?: string | null
          snomed_tpuu?: string | null
          status?: string | null
          updated_at?: number | null
          z_code?: string | null
        }
        Relationships: []
      }
      public_categories: {
        Row: {
          id: number
          name_en: string | null
          order_index: number | null
          parent: number | null
          raw_data: Json | null
        }
        Insert: {
          id: number
          name_en?: string | null
          order_index?: number | null
          parent?: number | null
          raw_data?: Json | null
        }
        Update: {
          id?: number
          name_en?: string | null
          order_index?: number | null
          parent?: number | null
          raw_data?: Json | null
        }
        Relationships: []
      }
      sync_errors: {
        Row: {
          created_at: string | null
          error_data: Json | null
          error_message: string | null
          id: number
          sync_type: string | null
        }
        Insert: {
          created_at?: string | null
          error_data?: Json | null
          error_message?: string | null
          id?: number
          sync_type?: string | null
        }
        Update: {
          created_at?: string | null
          error_data?: Json | null
          error_message?: string | null
          id?: number
          sync_type?: string | null
        }
        Relationships: []
      }
      sync_state: {
        Row: {
          chunk_status: string | null
          current_page: number | null
          entity_type: string
          last_sync_status: string | null
          last_sync_timestamp: number | null
          sync_count: number | null
          updated_at: string | null
        }
        Insert: {
          chunk_status?: string | null
          current_page?: number | null
          entity_type: string
          last_sync_status?: string | null
          last_sync_timestamp?: number | null
          sync_count?: number | null
          updated_at?: string | null
        }
        Update: {
          chunk_status?: string | null
          current_page?: number | null
          entity_type?: string
          last_sync_status?: string | null
          last_sync_timestamp?: number | null
          sync_count?: number | null
          updated_at?: string | null
        }
        Relationships: []
      }
    }
    Views: {
      sync_dashboard: {
        Row: {
          current_page: number | null
          entity_type: string | null
          items_synced: number | null
          last_sync_at: string | null
          last_sync_status: string | null
          minutes_since_last_sync: number | null
        }
        Insert: {
          current_page?: number | null
          entity_type?: string | null
          items_synced?: number | null
          last_sync_at?: never
          last_sync_status?: string | null
          minutes_since_last_sync?: never
        }
        Update: {
          current_page?: number | null
          entity_type?: string | null
          items_synced?: number | null
          last_sync_at?: never
          last_sync_status?: string | null
          minutes_since_last_sync?: never
        }
        Relationships: []
      }
    }
    Functions: {
      build_medipim_request_body: {
        Args: { task_data: Json }
        Returns: Json
      }
      clear_response_backlog: {
        Args: Record<PropertyKey, never>
        Returns: string
      }
      enhanced_process_sync_task: {
        Args: Record<PropertyKey, never>
        Returns: undefined
      }
      fast_api_processor: {
        Args: Record<PropertyKey, never>
        Returns: string
      }
      insert_products_from_response: {
        Args: { api_response: Json; request_id: number }
        Returns: number
      }
      instant_response_processor: {
        Args: Record<PropertyKey, never>
        Returns: string
      }
      pgmq_send: {
        Args: { queue_name: string; message: Json }
        Returns: number
      }
      process_deferred_relationships: {
        Args: Record<PropertyKey, never>
        Returns: number
      }
      process_sync_responses: {
        Args: Record<PropertyKey, never>
        Returns: undefined
      }
      process_sync_task: {
        Args: Record<PropertyKey, never>
        Returns: undefined
      }
      process_sync_tasks_batch: {
        Args: Record<PropertyKey, never>
        Returns: string
      }
      queue_products_aggressively: {
        Args: Record<PropertyKey, never>
        Returns: string
      }
      queue_sync_tasks: {
        Args: Record<PropertyKey, never>
        Returns: string
      }
      queue_sync_tasks_aggressive: {
        Args: Record<PropertyKey, never>
        Returns: string
      }
      repair_category_parent_relationships: {
        Args: Record<PropertyKey, never>
        Returns: undefined
      }
      repair_product_relationships: {
        Args: Record<PropertyKey, never>
        Returns: undefined
      }
      reset_stuck_syncs: {
        Args: { hours_threshold?: number }
        Returns: {
          entity_type: string
          was_stuck: boolean
        }[]
      }
      smart_sync_requester: {
        Args: Record<PropertyKey, never>
        Returns: string
      }
      store_entity_data: {
        Args: { entity_type: string; item_data: Json }
        Returns: undefined
      }
      store_product_relationships: {
        Args: { product_id: string; product_data: Json }
        Returns: undefined
      }
      test_entity_sorting_formats: {
        Args: Record<PropertyKey, never>
        Returns: {
          entity_type: string
          simple_format_works: boolean
          nested_format_works: boolean
        }[]
      }
      test_single_entity_request: {
        Args: { entity_type_param: string; use_nested_format?: boolean }
        Returns: number
      }
      update_sync_progress: {
        Args:
          | {
              entity_type: string
              completed_page: number
              has_more_pages: boolean
            }
          | { request_id: number; api_response: Json }
        Returns: undefined
      }
    }
    Enums: {
      [_ in never]: never
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DefaultSchema = Database[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof Database },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof Database
  }
    ? keyof (Database[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        Database[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never,
> = DefaultSchemaTableNameOrOptions extends { schema: keyof Database }
  ? (Database[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      Database[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof Database },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof Database
  }
    ? keyof Database[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends { schema: keyof Database }
  ? Database[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof Database },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof Database
  }
    ? keyof Database[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends { schema: keyof Database }
  ? Database[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof Database },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof Database
  }
    ? keyof Database[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never,
> = DefaultSchemaEnumNameOrOptions extends { schema: keyof Database }
  ? Database[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof Database },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof Database
  }
    ? keyof Database[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never,
> = PublicCompositeTypeNameOrOptions extends { schema: keyof Database }
  ? Database[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  graphql_public: {
    Enums: {},
  },
  public: {
    Enums: {},
  },
} as const
